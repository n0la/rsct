package RSCT;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Cookies;
use JSON;

use constant {
    LOGGEDOUT => 0,
    MAINVIEW => 1,
    MONTHLYVIEW => 2,
};

sub new
{
    my $name = shift;
    my $self = {};

    my $url = shift;
    my $ua = shift;

    $self->{'url'} = $url;
    $self->{'_reqcnt'} = 0;
    $self->{'state'} = LOGGEDOUT;

    unless (defined $ua) {
        $ua = LWP::UserAgent->new();
        my $cookies = HTTP::Cookies->new();
        $ua->agent("rsct/1.0");
        $ua->cookie_jar($cookies);

        $self->{'_cookies'} = $cookies;
        $self->{'ua'} = $ua;
    }

    bless $self, $name;

    return $self;
}

sub _do_request
{
    my $self = shift;
    my $content = shift;
    my $json = decode_json($content);

    # Update request counter if we have one.
    if (defined $json->{'head'} and
        defined $json->{'head'}->{'requestCounter'}) {
        my $counter = $self->{'_reqcnt'};
        $json->{'head'}->{'requestCounter'} = ++$counter;
        $self->{'_reqcnt'} = $counter;

        $content = encode_json($json);
    }

    my $req = HTTP::Request->new(POST => $self->{'url'});
    $req->content_type('application/json; charset=UTF-8');
    $req->header('Accept-Language' => 'en-US,en;q=0.5');
    $req->content($content);

    my $resp = $self->{'ua'}->request($req);

    return ($req, $resp);
}

sub _get_widgets {
    my $self = shift;
    my $json = shift;

    my @ops;

    @ops = @{$json->{'operations'}};
    my %widgets;

    foreach my $op (@ops) {
        my $cmd = $op->[0];
        my $name = $op->[1];

        if ($cmd eq 'create') {
            my %widget;

            %widget = %{$op->[3]};
            $widget{'name'} = $name;
            $widget{'type'} = $op->[2];

            $widgets{$op->[1]} = \%widget;

            $widget{'text'} = '' unless defined $widget{'text'};
            $widget{'type'} = '' unless defined $widget{'type'};
        } elsif ($cmd eq 'set') {
            my $widget = $widgets{$name};
            my %neu;

            # Update flags
            %neu = (%{$widget // {}}, %{$op->[2] // {}});
            $neu{'text'} = '' unless defined $neu{'text'};
            $neu{'type'} = '' unless defined $neu{'type'};

            $widgets{$name} = \%neu;
        }
    }

    return \%widgets;
}

sub _find_widget {
    my $self = shift;
    my $widgets = shift;
    my $matcher = shift;

    foreach my $value (values %{$widgets}) {
        if ($matcher->($value)) {
            return $value;
        }
    }

    return undef
}

sub _initialize {
    my $self = shift;
    my $req = HTTP::Request->new(GET => $self->{'url'});
    my $res = $self->{'ua'}->request($req);

    # Throw away cookie jar.
    $self->{'_cookies'} = HTTP::Cookies->new();
    $self->{'ua'}->cookie_jar($self->{'_cookies'});

    die('Could not contact URL: '.$self->{'url'})
        unless $res->is_success;

    # TODO: Send actual timezoneOffset
    my $inittemplate = <<"EOF";
{"head":{"rwt_initialize":true},"operations":[
["set","w1",{"bounds":[0,0,1680,926],"dpi":[96,96],"colorDepth":32}],
["set","rwt.client.ClientInfo",{"timezoneOffset":-60}],
["call","rwt.client.TextSizeMeasurement","storeMeasurements",{"results":
{"p-1863599590":[659,16],"p-716633329":[918,19],
 "p-716630769":[817,17],"p-716634865":[1759,36],
 "p-716630770":[733,17],"p-716633330":[836,19],
 "p1122287368":[770,16], "p1122286600":[832,17],
 "p1122282248":[1490,30],"p839638919":[765,17],
 "p1122287113":[666,14],"p1122286601":[772,17]}}],
["set","w1",{"cursorLocation":[0,0]}]
]}
EOF

    ($req, $res) = $self->_do_request($inittemplate);

    die('Failed to initialize session')
      unless $res->is_success;

    my $j = decode_json($res->content);
    my $name;
    my $widgets;

    $widgets = $self->_get_widgets($j);

    # Find username field.
    $name = $self->_find_widget($widgets,
                                sub {
                                    return ($_[0]->{'type'} eq 'rwt.widgets.Text' and
                                            not defined $_[0]->{'echoChar'});
                                });
    die('Could not find username field.')
      unless defined $name;
    $name = $name->{'name'};

    $self->{'_widget_user'} = $name;

    # Find password field.
    $name = $self->_find_widget($widgets,
                                sub {
                                    return (defined $_[0]->{'echoChar'});
                                });
    die('Could not find username field.')
      unless defined $name;
    $name = $name->{'name'};
    # Find login field
    $self->{'_widget_pass'} = $name;

    $name = $self->_find_widget($widgets,
                                sub {
                                    return ($_[0]->{'text'} eq 'Log in');
                                });
    die('Could not find username field.')
      unless defined $name;
    $name = $name->{'name'};
    $self->{'_widget_login'} = $name;
}

sub _press_button {
    my $self = shift;
    my $w = shift;

    my $btn = $w->{'name'};
    my $btntemplate = <<"EOF";
{"head":{"requestCounter":0},
"operations":[
["notify","$btn","Selection",{"shiftKey":false,"ctrlKey":false,"altKey":false}],
["set","w1",{"cursorLocation":[1159,556]}]
]}
EOF

    return $self->_do_request($btntemplate);
}

sub _parse_overview {
    my $self = shift;
    my $widgets;

    $widgets = $self->_get_widgets($self->{'_overview'});
    $self->{'_overview_widgets'} = $widgets;

    my $flexitime = $self->_find_widget($widgets,
                                        sub {
                                            return ($_[0]->{'text'} =~
                                                    m/([-]*\d+\:\d+) hours/i);
                                        });

    die('Could not find flexitime in overview.')
      unless defined $flexitime;

    ($self->{'flexitime'}) = ($flexitime->{'text'} =~ m/([-]*\d+\:\d+)/ig);

    my $leave = $self->_find_widget($widgets,
                                    sub {
                                        return ($_[0]->{'text'} =~
                                                m/([-]*\d+\.\d+) days/i);
                                    });

    die('Could not find flexitime in overview.')
      unless defined $leave;

    ($self->{'leave'}) = ($leave->{'text'} =~ m/([-]*\d+\.\d+)/ig);

    # Find go and come button
    my $go = $self->_find_widget($widgets, sub {
                                     return ($_[0]->{'text'} =~ m/Go/g);
                                 });

    $self->{'_main_go'} = $go;

    my $come = $self->_find_widget($widgets, sub {
                                     return ($_[0]->{'text'} =~ m/Come/g);
                                 });

    $self->{'_main_come'} = $come;

    # Parse positions
    my @positions;

    $self->_find_widget($widgets,
                        sub {
                            if ($_[0]->{'type'} =~ m/rwt\.widgets\.GridItem/i) {
                                if ($_[0]->{'texts'}) {
                                    my @arr = @{$_[0]->{'texts'}};
                                    my $elem = {
                                                'time' => $arr[2],
                                                'type' => $arr[3]
                                               };
                                    push(@positions, $elem);
                                }
                            }
                            return 0;
                        });

    $self->{'positions'} = \@positions;

    # Find widget for overview.
    my $monthly = $self->_find_widget($widgets,
                                      sub {
                                          return ($_[0]->{'text'} =~
                                                  m/monthly survey/i);
                                      });
    die('Could not find button for monthly survey')
      unless defined $monthly;

    my $logout = $self->_find_widget($widgets,
                                     sub {
                                         return (shift->{'text'} =~ m/logout/i);
                                     });
    die('Could not find "Logout" button')
      unless defined $logout;
    $self->{'_main_logout'} = $logout;

    $self->{'_monthly_button'} = $monthly;
}

sub positions {
    my @empty;
    return shift->{'positions'} // \@empty;
}

sub leave {
    return shift->{'leave'};
}

sub flexitime {
    return shift->{'flexitime'};
}

sub login {
    my $self = shift;

    die('Already logged in?')
      unless $self->state == LOGGEDOUT;

    my $user = shift;
    my $pass = shift;

    $self->_initialize();

    my $wuser = $self->{'_widget_user'};
    my $wpass = $self->{'_widget_pass'};
    my $wlogin = $self->{'_widget_login'};

    my $logintemplate = <<"EOF";
{"head":{"requestCounter":0},
"operations":[
["set","$wuser",{"selectionStart":6,"selectionLength":0,"text":"$user"}],
["notify","w15","FocusOut",{}],["notify","w16","FocusIn",{}],
["set","w2",{"activeControl":"w16"}],
["set","w1",{"cursorLocation":[863,400],"focusControl":"w16"}],
["set","$wpass",{"selectionStart":8,"selectionLength":0,"text":"$pass"}],
["notify","w16","FocusOut",{}],["set","w2",{"activeControl":"w18"}],
["set","w1",{"cursorLocation":[931,508],"focusControl":"w18"}],
["notify","$wlogin","Selection",{"shiftKey":false,"ctrlKey":false,"altKey":false}],
["set","w1",{"cursorLocation":[945,503]}]
]}
EOF

    my ($req, $res) = $self->_do_request($logintemplate);

    die('Could not login.')
      unless $res->is_success;

    my $j = decode_json($res->content);
    my $w = $self->_get_widgets($j);

    my $confirm = $self->_find_widget($w,
                                      sub {
                                          return ($_[0]->{'text'} =~
                                                  m/User \'$user\' is alrea/i);
                                      });
    if (defined $confirm) {
        # Confirm login.
        my $yes = $self->_find_widget($w,
                                      sub {
                                          return ($_[0]->{'text'} =~
                                                  m/yes/i);
                                      });

        die('Could not find "Yes" button in confirm dialog.')
          unless defined $yes;
        $yes = $yes->{'name'};

        my $confirmtemplate = <<"EOF";
{"head":{"requestCounter":0},
"operations":[
["notify","$yes","Selection",{"shiftKey":false,"ctrlKey":false,"altKey":false}]
]}
EOF
        ($req, $res) = $self->_do_request($confirmtemplate);

        die('Could not confirm login.')
          unless $res->is_success;
    }

    $self->{'_overview'} = decode_json($res->content);
    # Parse overview
    $self->_parse_overview();

    $self->{'state'} = MAINVIEW;
}

sub _parse_month {
    my $self = shift;
    my $j = shift;
    my @days;
    my $month;
    my $year;
    my %result;

    my $yearfinder = sub {
        my $widget = shift;

        if ($widget->{'text'} =~ m/monthly survey\s+([^\s]+)\s+(\d+)/i) {
            $result{'year'} = $2;
        }
    };

    my $finder = sub {
        my $widget = shift;

        if ($widget->{'type'} =~ m/rwt\.widgets\.GridItem/i and
            defined $widget->{'texts'}) {
            my @texts = @{$widget->{'texts'}};

            my $date = $texts[0];

            if ($date =~ m/(\d+).(\d+)\s+(\w+)/i) {
                my $day = $1;
                my $month = $2;
                my $weekday = $3;

                my $entry = {'day' => $day,
                             'weekday' => $weekday,
                             'date' => "$day.$month.$result{'year'}",
                             'come_sta' => $texts[1],
                             'come_rou' => $texts[2],
                             'come_ass' => $texts[3],
                             'go_sta' => $texts[4],
                             'go_rou' => $texts[5],
                             'go_ass' => $texts[6],
                             'absence' => $texts[7],
                             'profile' => $texts[8],
                             'break' => $texts[9],
                             'target' => $texts[10],
                             'fb' => $texts[11],
                             'present' => $texts[12],
                             'ftday' => $texts[13],
                             'ftmonth' => $texts[14],
                             'fttotal' => $texts[15],
                            };
                push(@days, $entry);

                $result{'month'} = $month;
            }
        }

        return 0;
    };

    my $w = $self->_get_widgets($j);
    $self->_find_widget($w, $yearfinder);

    die('Could not parse year from view.')
      unless defined $result{'year'};

    $self->_find_widget($w, $finder);

    # Sort days
    @days = sort { int($a->{'day'}) <=> int($b->{'day'}) } @days;

    $result{'days'} = \@days;

    return \%result;
}

sub state {
    return shift->{'state'};
}

sub _move_month {
    my $self = shift;
    my $dir = shift;

    die('Not in monthly overview')
      unless $self->state == MONTHLYVIEW;

    my $btn = $self->{"_monthly_$dir"};
    my ($req, $res) = $self->_press_button($btn);

    die('Could not move '.$dir.' in month.')
      unless $res->is_success;

    return $self->_parse_month(decode_json($res->content));
}

sub prev_month {
    my $self = shift;

    return $self->_move_month('back');
}

sub next_month {
    my $self = shift;

    return $self->_move_month('forward');
}

sub come {
    my $self = shift;

    if ($self->state == MONTHLYVIEW) {
        # Switch back to main view.
        $self->main_view();
    }

    my $btn = $self->{'_main_come'};

    die('No "Come" button. Perhaps not stamped out?')
      unless $btn;

    my ($req, $res) = $self->_press_button($btn);

    die('Could not stamp you in.')
      unless $res->is_success;

    my $j = decode_json($res->content);
    my $w = $self->_get_widgets($j);

    my $confirm = $self->_find_widget($w, sub {
                                          return ($_[0]->{'text'} =~ m/OK/);
                                      });

    die('No confirm button for stamping in.')
      unless $confirm;

    ($req, $res) = $self->_press_button($confirm);
    die('Could not confirm stamp in.')
      unless $res->is_success;
}

sub go {
    my $self = shift;

    if ($self->state == MONTHLYVIEW) {
        # Switch back to main view.
        $self->main_view();
    }

    my $btn = $self->{'_main_go'};

    die('No go button. Perhaps not stamped in?')
      unless $btn;

    my ($req, $res) = $self->_press_button($btn);

    die('Could not stamp you out.')
      unless $res->is_success;

    my $j = decode_json($res->content);
    my $w = $self->_get_widgets($j);

    my $confirm = $self->_find_widget($w, sub {
                                          return ($_[0]->{'text'} =~ m/OK/);
                                      });

    die('No confirm button for stamping out.')
      unless $confirm;

    ($req, $res) = $self->_press_button($confirm);
    die('Could not confirm stamp out.')
      unless $res->is_success;
}

sub is_stamped_in {
    my $self = shift;
    return defined $self->{'_main_go'};
}

sub main_view {
    my $self = shift;

    die('Not in monthly view')
      unless  $self->state == MONTHLYVIEW;

    my $btn = $self->{'_monthly_main'};
    my ($req, $res) = $self->_press_button($btn);

    die('Could not get monthly survey.')
      unless $res->is_success;

    # JWT simply destroys the monthly view and selects the
    # main view. There's nothing to parse and nothing else
    # todo here.

    $self->{'state'} = MAINVIEW;
}

sub monthly_view {
    my $self = shift;

    # We can only
    die('Not in main view')
      unless $self->state == MAINVIEW;

    my $btn = $self->{'_monthly_button'};
    my ($req, $res) = $self->_press_button($btn);

    die('Could not get monthly survey.')
      unless $res->is_success;

    my $month = decode_json($res->content);

    my $w = $self->_get_widgets($month);

    # Find buttons for previous/forward
    my $back = $self->_find_widget($w,
                                   sub {
                                       return (shift->{'text'} =~
                                               m/Month back/i);
                                   });
    die('Could not find "Month back" button')
      unless defined $back;
    $self->{'_monthly_back'} = $back;

    my $forward = $self->_find_widget($w,
                                      sub {
                                          return (shift->{'text'} =~
                                                  m/Month foward/i);
                                      });
    die('Could not find "Month forward" button')
      unless defined $back;
    $self->{'_monthly_foward'} = $forward;

    my $main = $self->_find_widget($w,
                                   sub {
                                       return (shift->{'text'} =~
                                               m/back to main view/i);
                                   });
    die('Could not find "Back to main view" button')
      unless defined $main;
    $self->{'_monthly_main'} = $main;

    # Update state.
    $self->{'state'} = MONTHLYVIEW;

    return $self->_parse_month($month);
}

sub logout {
    my $self = shift;

    # Already logged out.
    return if $self->state == LOGGEDOUT;

    if ($self->state == MONTHLYVIEW) {
        # Switch back to main view.
        $self->main_view();
    }

    my ($req, $res) = $self->_press_button($self->{'_main_logout'});

    die('Could not logout')
      unless $res->is_success;

    $self->{'state'} == LOGGEDOUT;
}

return 1;

=head1 NAME

RSCT - fetch information by parsing ReinerSCT web frontend

=head1 DESCRIPTION

The RSCT module fetches information about booked times from the ReinerSCT web
frontend by navigating and parsing the web front end. This module will not
emulate whatever protocol ReinerSCT has between its GUI and the server.

Main features of this module are:

=over 2

=item *

Object oriented API.

=item *

Fetching and parsing of todays positions.

=item *

Fetching and parsing of the monthly overview, including any past months.

=back

ReinerSCT web view is a JWT (Java) based "Web GUI" that uses JSON to send data
across HTTP or HTTPs. These JSON objects contain instructions for the JavaScript
framework on how to build a GUI. To navigate this GUI the client JavaScript
sends JSON objects to the server.

The RSCT web application has two "views": The main view giving a rough overview
of the current day, and a summary of common values: flexitime credit, leave
credit etc. And a monthly overview that shows an overview of the month. An RSCT
object can only be in one of those views at a time. The monthly view can only
be navigated by going "back" and "forth".

Also note that only one session per user can be opened at a time. The RSCT
object will override any other open sessions upon login.

=head2 RSCT object

The following properties are available for read access through your
RSCT object:

=over 2

=item *

B<state> represents the current state of the web state machine. The initial
state is B<LOGGEDOUT> and will change aftering calling methods. After a
successful login, and parsing of the main view it will be B<MAINVIEW>. From
there one can switch the monthly overview after which state will be
B<MONTHLYVIEW>.

=item *

B<flexitime> represents the current amount of Flextime credit (in hours) that
was shown on the main view.

=item *

B<leave> is the current amount of leave credit (most of the time, in days) that
is shown in the main view.

=item *

B<positions> is an array that contains the current booking positions for today.
Each element is a hashref with two elements: B<time> is the time when the
position was booked (HH:MM [AM|PM]), and B<type> is either 'Come' or 'Go'.

=back

The following methods are available:

=over 2

=item new(url)

Constructs a new RSCT object. The specified URL should point to the ReinerSCT
web application (usually http://example.com/reiner-sct/pcterminal).

=item login(username, password)

Will login the given username and password. Any other sessions will be
terminated, and if everything was successful it will parse the overview of
the web terminal. The data parsed from this operation will be available in
B<flexitime>, B<leave> and B<positions>.

The state will switch from B<LOGGEDOUT> to B<MAINVIEW>.

=item monthly_view()

This method will switch from the main view to the monthly overview. If this
succeeds the method will return a hashref containing the data of the current
month

=item prev_month()

In monthly view, will navigate one month back. It will return a month hashref
for the last month.

=item next_month()

In monthly view, will naviate one month forward. It will return a month hashref
for the next month.

=back

=head2 MONTH HASHREF

B<monthly_view>, B<prev_month> and B<next_month> return a hashref containing
all the information about the month they just parsed. The data format is
described below.

This hashref has the following members: B<year> is the current year,
B<month> is the month, and B<days> is a sorted (based on the day) array of
hashrefs containing the data for each individual day. The day hashrefs have
the following fields:

=over 2

=item * B<day>

The day of the month.

=item * B<weekday>

The weekday shortened to two letters (English).

=item * B<date>

Full date (DD.MM.YYYY).

=item * B<come_sta>

First stamped 'Come' timestamp marking the beginning of the time calculation.

=item * B<come_rou>

Unknown.

=item * B<come_ass>

Unknown.

=item * B<go_sta>

Last stamped 'Go' timestamp marking the end of the time calculation.

=item * B<absence>

Reason for absence (i.e. public holiday). This is usually a display string that
is shortened to fit into GUI. It's best to only use it's presence as an
indicator that the person was absent for this day.

=item * B<profile>

The profile this person is assigned.

=item * B<break>

Duration of the break for this day (in hours).

=item * B<target>

The target time (in hours) that must be reached on this day.

=item * B<fb>

Unknown.

=item * B<present>

The amount of time present (in hours).

=item * B<ftday>

Amount of flexitime credit earned this day. Can also be negative to denote that
flexitime was lost by working less than B<target>.

=item * B<ftmonth>

Flexitime earned (or lost) this month up unto the given day. Can also be
negative.

=item * B<fttotal>

Amount of flexitime as it was on this day (total).

=back

=head2 An Example

The following example will parse all months, starting with new newest and
going back until no more data can be found:

  use RSCT;

  my $done = 0;
  my $month;
  my $rsct = RSCT->new('http://example.com/reiner-sct/pcterminal');
  $rsct->login('user', 'pass');

  $month = $rsct->monthly_view();

  do {
    export_to_csv($month);
    eval {
      $month = $rsct->prev_month();
    };
    if ($@) {
      $done = 1;
    }
  } while (not $done);

=head1 AUTHORS

RSCT was written by Florian Stinglmayr <florian@n0la.org>

=head1 COPYRIGHT

  Copyright 2015 Florian Stinglmayr

=cut

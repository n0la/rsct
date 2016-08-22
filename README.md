# RSCT

RSCT is a perl library and application that allows you to fetch information from
the Reiner SCT web terminal.

# Installation

Dependencies:

 * JSON
 * LWP::UserAgent
 * HTTP::Cookies
 * YAML::XS
 * Term::ReadPassword

# Usage

## Overview

The _overview_ command is there to show you a human readable overview of your
current situtation. It prints your current flexitime, leave days, a daily report
of any 'come' and 'go', and a monthly overview of the current month.

## Export

The export command allows you to export the monthly data to CSV. Use the option
_--output_ to specify a file or alternatively a directory. If a directory is
specified, each month will be exported into a separate file. If you specify
_--all_ all months are exported. _rsct_ does this by starting with the current
month and walking backwards, until no more data can be found. If a file is
specified all data is dumped into one CSV file.

## Come & Go

Use these commands to stamp in and out. These command are not capable of
specifying subtypes (such as marking holidays, special days of etc.) and
will only use the default settings provided in the overview dialogue.

## Status

This command will print whether you are currently stamped in or out.

# Documentation

Run the following for more information:

```
$ perldoc rsct
```

or

```
$ ./rsct help
```

For a guide on how to use the RSCT perl module:

```
$ perldoc RSCT
```

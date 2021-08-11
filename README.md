# NAME

App::MechaCPAN - Mechanize the installation of CPAN things.

# SYNOPSIS

    # Install 5.24 into local/perl/
    user@host:~$ mechacpan perl 5.24
    
    # Install Catalyst into local/
    user@host:~$ mechacpan install Catalyst
    
    # Install everything from the cpanfile into local/
    # If cpanfile.snapshot exists, it will be consulted first
    user@host:~$ mechacpan install
    
    # Install perl and everything from the cpanfile into local/
    # If cpanfile.snapshot exists, it will be consulted exclusivly
    user@host:~$ mechacpan deploy
    user@host:~$ zhuli do the thing

# DESCRIPTION

App::MechaCPAN Mechanizes the installation of perl and CPAN modules.
It is designed to be small and focuses more on installing things in a self-contained manner. That means that everything is installed into a `local/` directory.

MechaCPAN was created because installation of a self-contained deployment required at least 4 tools:

- plenv/Perl-Build or perlbrew to manage perl installations
- cpanm to install packages
- local::lib to use locally installed modules
- carton to manage and deploy exact package versions

In development these tools are invaluable, but when deploying a package, installing at least 4 packages from github, CPAN and the web just for a small portion of each tool is more than needed. App::MechaCPAN aims to be a single tool that can be used for deploying packages in a automated fashion.

App::MechaCPAN focuses on the aspects of these tools needed for deploying packages to a system. For instance, it will read and use carton's `cpanfile.snapshot` files, but cannot create them. To create `cpanfile.snapshot files`, you must use carton.

## Should I use App::MechaCPAN instead of &lt;tool>

Probably not, no. It can be used in place of some tools, but its focus is not on the features a developer needs. If your needs are very simple and you don't need many options, you might be able to get away with only using `App::MechaCPAN`. However be prepared to run into limitations quickly.

# USING FOR DEPLOYMENTS

## COMMANDS

    user@host:~/project/$ ls -la
    drwxr-xr-x  6 user users 20480 Jan 18 13:00 .
    drwxr-xr-x 25 user users  4096 Jan 18 13:00 ..
    drwxr-xr-x  8 user users  4096 Jan 18 13:05 .git
    -rw-r--r--  1 user users     7 Jan 18 13:06 .perl-version
    -rw-r--r--  1 user users   109 Jan 18 13:06 cpanfile
    drwxr-xr-x  3 user users  4096 Jan 18 13:10 lib
    
    user@host:~/project/$ mechacpan deploy

That command will do 2 things:

- Install perl

    It will install perl into the directory local/perl.  It will use the version in `.perl-version` to decide what version will be installed.

- Install modules

    Then it will use the installed perl to install all the module dependencies that are listed in the cpanfile.

# COMMANDS

## Perl

    user@host:~$ mechacpan perl 5.24

The [perl](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3APerl) command is used to install [perl](https://metacpan.org/pod/perl) into `local/`. This removes the packages dependency on the operating system perl. By default, it tries to be helpful and include `lib/` and `local/` into `@INC` automatically, but this feature can be disabled. See [App::MechaCPAN::Perl](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3APerl) for more details.

## Install

    user@host:~$ mechacpan install Catalyst

The [install](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3AInstall) command is used for installing specific modules. All modules are installed into the `local/` directory. See See [App::MechaCPAN::Install](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3AInstall) for more details.

## Deploy

    user@host:~$ mechacpan deploy

The [deploy](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3ADeploy) command is used for automating a deployment. It will install both [perl](https://metacpan.org/pod/perl) and all the modules specified from the `cpanfile`. If there is a `cpanfile.snapshot` that was created by [Carton](https://metacpan.org/pod/Carton), `deploy` will treat the modules lised in the snapshot file as the only modules available to install. See [App::MechaCPAN::Deploy](https://metacpan.org/pod/App%3A%3AMechaCPAN%3A%3ADeploy) for more details.

# OPTIONS

Besides the options that the individual commands take, `App::MechaCPAN` takes several that are always available.

## --verbose

By default only informational descriptions of what is happening is shown. Turning verbose on will show every command and all output produced by running each command. Note that this is **not** the opposite of quiet.

## --quiet

Using quiet means that the normal information descriptions are hidden. Note that this is **not** the opposite of verbose, turning both options on means no descriptions will be show, but all output from all commands will be.

## --no-log

A log is normally outputted into the `local/logs` directory. This option will prevent a log from being created.

## --directory=&lt;path>

Changes to a specified directory before any processing is done. This allows you to specify what directory you want `local/` to be in. If this isn't provided, the current working directory is used instead.

## `$ENV{MECHACPAN_TIMEOUT}`

Every command that `App::MechaCPAN` runs is given an idle timeout before it is killed and a failure is returned. This timeout is reset every time the command outputs to `STDOUT` or `STDERR`. Using the environment variable `MECHACPAN_TIMEOUT`, you can override or disable this timeout. It is always in seconds and setting it to 0 will disable it. The default is 60 seconds.

# SCRIPT RESTART WARNING

This module **WILL** restart the running script **IF** it's used as a module (e.g. with `use`) and the perl that is running is not the version installed in `local/`. It does this at two points: First right before run-time and Second right after a perl is installed into `local/`. During restart, `App::MechaCPAN` will attempt to install itself into `local/` unless it was invoked as a fully-contained version of `mechacpan`.

The scripts and modules that come with `App::MechaCPAN` are prepared to handle this. If you use `App::MechaCPAN` as a module, you should to be prepared to handle it as well.

This means that any END and DESTROY blocks **WILL NOT RUN**. Anything created with File::Temp will be cleaned up, however.

# AUTHOR

Jon Gentle <cpan@atrodo.org>

# COPYRIGHT

Copyright 2017- Jon Gentle

# LICENSE

This is free software. You may redistribute copies of it under the terms of the Artistic License 2 as published by The Perl Foundation.

# SEE ALSO

- [App::cpanminus](https://metacpan.org/pod/App%3A%3Acpanminus)
- [local::lib](https://metacpan.org/pod/local%3A%3Alib)
- [Carton](https://metacpan.org/pod/Carton)
- [CPAN](https://metacpan.org/pod/CPAN)
- [plenv](https://github.com/tokuhirom/plenv)
- [App::perlbrew](https://metacpan.org/pod/App%3A%3Aperlbrew)

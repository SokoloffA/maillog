#!/usr/bin/perl
# Анализатор почтовых логов
# Ver 1.6
#
# Copyright (C) 2010 Alexander Sokoloff <asokol@mail.ru>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.

# Использование: maillog [-d DATE] [-f FROM] [-t TO] [-e] [-h] [-V]
#
# Показывает записи в почтовом логе для писем идущих с адреса FROM к
# адресу TO за период указаный в опции DATE.
#
#   -f FROM почтовый адрес отправителя (или его часть).
#
#   -t TO   почтовый адрес получателя (или его часть).
#
#   -d DATE выводить отчет за указанный период, если опция пропущена
#           выводятся записи только за текущий день.
#
#     DD/MM/YY-DD/MM/YY   Полный формат:
#        -DD/MM/YY   Пропущена начальная дата:
#                    будут показаны записи с 1 января 1970 года.
#      DD/MM/YY-     Пропущена конечная дата:
#                    будут показаны записи до текущей даты.
#       -            Пропущена как начальная, так и конечная даты:
#                    будут показаны записи с 1 января 1970 года до
#                    текущей даты.
#
#   -e      показывать только недоставленные сообщения.
#
#   -h      показать страницу помощи.
#
#   -V      показать версию программы и лицензию.

# Settings ###################################################################

my $filePattern='/var/log/mail/mail*.{log,log.gz}';
my $LESS="less -S -R --shift=1";

use strict;
use Time::Local;


# Set constants ***************************************************************
my $DAY=3; my $MON=4; my $YEAR=5;
my %MONTHS=('Jan'=>0,'Feb'=>1,'Mar'=>2,'Apr'=>3,'May'=>4,'Jun'=>5,'Jul'=>6,'Aug'=>7,'Sep'=>8,'Oct'=>9,'Nov'=>10,'Dec'=>11);


# Set default values **********************************************************
my @now=localtime();
my $bDate= timelocal(0,  0,  0,  $now[$DAY], $now[$MON], $now[$YEAR]);
my $eDate= timelocal(59, 59, 23, $now[$DAY], $now[$MON], $now[$YEAR]);

my $from='';
my $to='';
my $errors=0;
my $verbose=0;
my $stat=0;

my %msgs;
my $optLimit = 0; # For scan optimization

param(@ARGV);

scan($filePattern, $bDate, $eDate);

clean();

printResults();

exit;



#*******************************************************************************
# Main scan function
#*******************************************************************************
sub scan
{
    my $pattern = $_[0];
    my @lt = localtime($_[1]);
    my $start = sprintf("%02d%02d", $lt[$MON], $lt[$DAY]);
    @lt = localtime($_[2]);
    my $stop  = sprintf("%02d%02d", $lt[$MON], $lt[$DAY]);

    foreach my $file (sort{$b cmp $a}(glob($pattern)))
    {
        scanFile($file, $start, $stop);
    }

}


#*******************************************************************************
# Scan single file
#*******************************************************************************
sub scanFile
{
    my $fileName = shift;
    my $start = shift;
    my $stop = shift;

    my $mime = `file --mime-type "$fileName"`;
    if ($mime=~ m@application/gzip|application/x-gzip@)
    {
        open(FILE, "zcat \"$fileName\" |") or die "Can't open \"$fileName\" file.";
    }
    else
    {
        open(FILE, $fileName) or die "Can't open \"$fileName\" file.";
    }


    while (<FILE>)
    {
        next if (!(m/^(\S\S\S) +(\d?\d)/));

        next if !exists $MONTHS{$1};
        my $iDate = sprintf("%02d%02d", $MONTHS{$1}, $2);

        # Some optimizations .........................
        if ($iDate<$start && $optLimit<$iDate)
        {
            $optLimit = $iDate;
        }

        last if ($iDate<$optLimit);
        next if ($iDate<$start);
        last if ($iDate>$stop);
        # ............................................


        #            1        2            3          4     5     6
        next if (!(m/^(\S\S\S) +(\d?\d) (\d\d:\d\d:\d\d) (\S+) (\S+): (.*)/));

        my $date="$2 $1";
        my $time=$3;
        my $proc=$5;
        my $msg=$6;

        my $id;
        my $text;
        ($id, $text) = parsePostfixLine($msg)   if ($proc =~ m/^postfix/);
        ($id, $text) = parseAmavisLine($msg)    if ($proc =~ m/^amavis/);

        if ($id)
        {
            $msgs{$id}{'order'}=$date . $time;
            $msgs{$id}{'date'}=$date;
            $msgs{$id}{'msg'}.="\n $time " . (($verbose)?$proc:'') . " $text";
        };
    };
    close(FILE);
};


#******************************************************************************
# Parse lines from Postfix
#******************************************************************************
sub parsePostfixLine
{
    my $msg  = shift;

    if ($msg=~ m/^([0-9A-Fa-f]+): (.*)/)
    {
        return ($1, $2);
    };
    return ("", "");
}


#******************************************************************************
# Parse lines from Amavis
#******************************************************************************
sub parseAmavisLine
{
    my $msg  = shift;
    if ($msg=~ m/(.*)Queue-ID: ([0-9A-Fa-f]+),(.*)/)
    {
        return ($2, "$1$3");

    }
    return ("", "");
}


#******************************************************************************
# Delete not matched records
#******************************************************************************
sub clean
{
    foreach my $key (keys(%msgs))
    {
        my $s=$msgs{$key}{'msg'};
        if ($to     && ($s!~ m/to=<\S*$to\S*>/i))
        {
            delete $msgs{$key};
            next;
        }

        if ($from   && ($s!~ m/from=<\S*$from\S*>/i))
        {
            delete $msgs{$key};
            next;
        }

        if ($errors && ($s=~ m/status=sent/i))
        {
            delete $msgs{$key};
            next;
        }
    }
}


#******************************************************************************
# Print results table
#******************************************************************************
sub printResults
{
    my $COLOR_NORM="\e[0;39m";
    my $COLOR_TO="\e[0;36m";
    my $COLOR_FROM="\e[0;33m";
    my $COLOR_OK="\e[0;32m";
    my $COLOR_BOUNCE="\e[0;31m";


    # Print results in LESS .............................
    my $num=scalar(keys(%msgs));
    open (PAGER, "| $LESS --prompt='Found $num mails.  Line %lt-%lb.'");

    foreach my $key (sort{$msgs{$a}{'order'} cmp $msgs{$b}{'order'}}(keys(%msgs)))
    {

        my $s=$msgs{$key}{'msg'};

        $s=~ s/to=<(.*?)>/to=<$COLOR_TO$1$COLOR_NORM>/g;
        $s=~ s/from=<(.*?)>/from=<$COLOR_FROM$1$COLOR_NORM>/g;

        my $status='';
        $status=$COLOR_OK     if ($s=~ s/(status=sent.*)/$COLOR_OK$1$COLOR_NORM/g);
        $status=$COLOR_BOUNCE if ($s=~ s/(status=bounced.*)/$COLOR_BOUNCE$1$COLOR_NORM/g);

        print PAGER sprintf("%s%s  ...............................%s%s\n%s\n\n\n",
                            $status,
                            $key,
                            $COLOR_NORM,
                            $msgs{$key}{'date'},
                            $s);
    }

    close(PAGER);
}


#******************************************************************************
# Parse comand-line parametres
#******************************************************************************
sub param
{
    my $param;
    while ($param=shift)
    {
        if    ($param eq '-h'){ help() }
        elsif ($param eq '-V'){ showVer() }
        elsif ($param eq '-v'){ $verbose++ }
        elsif ($param eq '-e'){ $errors = 1 }
        elsif ($param eq '-t'){ $to =   shift }
        elsif ($param eq '-f'){ $from = shift }
        elsif ($param eq '-d'){ parseDateParam(shift, $bDate, $eDate) }
    };

    $from=~ s/\./\\\./g;
    $to=~ s/\./\\\./g;
}


#*******************************************************************************
# Parse comandline date parameter $_[0] and set 2 variable:
# $_[1] - begin date and
# $_[2] - end date
#*******************************************************************************
sub parseDateParam($$$)
{
    (my $b, my $e)=split('-', $_[0], 2);
    $_[1]=str2date($b?$b:'01/01/1970');
    $_[2]=str2date($e) if $e;
    $_[2]=$_[1] if ($_[0]!~ m/-/);
}


#******************************************************************************
# Parse string & return timestamp
#******************************************************************************
sub str2date
{
    my ($d,$m,$y) = split ('\D', $_[0], 3);
    $m = $now[$MON]+1  if (!$m);
    $y = $now[$YEAR] if (!$y);
    return timelocal(0, 0, 0, $d, --$m, $y);
}


#******************************************************************************
# Print help message
#******************************************************************************
sub help
{
    open(FILE, $0);

    while (<FILE>)
    {
        last if $_ eq "\n";
    };

    while (<FILE>)
    {
        last if $_ eq "\n";
        s/^#//;
        print $_;
    };
    close FILE;
    exit;
}


#******************************************************************************
# Print version
#******************************************************************************
sub showVer
{
    open(FILE, $0);

    <FILE>;
    while (<FILE>)
    {
        last if $_ eq "\n";
        s/^#//;
        print $_;
    };
    close FILE;
    exit;
}

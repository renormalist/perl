#! /usr/bin/perl

# This program checks copyright years in Perl repository files.
#
# Usage:
#
#  $ Porting/check_copyright.pl
#  $ Porting/check_copyright.pl ./perl.c x2p/*
#
# It outputs TAP, so could directly be used as test script.

# Copyright (C) 2012 by Steffen Schwigon
# 
# You may distribute under the terms of either the GNU General Public
# License or the Artistic License, as specified in the README file.

use 5.010;
use strict;
use warnings;
use List::Util "max";

# Approach:
    
# - find "Copyright" and according context lines
# - from those extract greatest year
# - compare this to last git change
# - if commits happened after latest copyright year: show them for review
# - blacklist exceptions, like known files and commits to ignore
# - manual review of intermediate results, polishing the blacklists
    
# Caveats:
    
# - date semantics is always "CommitDate" (because I can only limit by that in git log)
# - there could be race conditions during year change due to local-vs-commit timezone gaps


# === exceptions and scope ===

my %SKIPLIST = map { ( $_ => 1 ) } (qw( ./Artistic
                                        ./embed.pl
                                        ./pod/perlmodlib.PL
                                        ./utils/h2xs.PL
                                        ./win32/bin/search.pl
                                        ./win32/fcrypt.c
                                        ./wince/bin/search.pl
                                        ./README
                                        ./patchlevel.h
                                     ));

# these commits do not contain copyright-worthy changes; short or long SHA1 allowed
my @SKIP_COMMITS = ( qr'^486ec47', # Fix typos (spelling errors) in Perl sources,  Peter J. Acklam
                     qr'^cdad3b5', # Convert some files from Latin-1 to UTF-8, Keith Thompson
                     qr'^4ac7155', # Large omnibus patch to clean up the JRRT quotes, Tom Christiansen
                     qr'^e9a8c09', # Add editor blocks to some header files, Marcus Holland-Moritz
                     qr'^9607fc9', # [inseparable changes from match from perl-5.003_91 to perl-5.003_92]
                     qr'^c255fa6', # Make everything exec-bit.txt lists executable, Florian Ragwitz
                     qr'^ff906f8', # Global executable bit cleanup, David Golden
                     qr'^ba05a73', # micro comment, Karl Williamson
                     qr'^eb86385', # Use alternative URLs for links which are now broken, Leon Brocard
                     qr'^378eeda', # The Borland Chainsaw Massacre, Steve Hay
                     qr'^8b88b2b', # Move Storable from ext/ to dist/, Nicholas Clark
                     qr'^dddb60f', # Convert all Storable's tests to use Test::More (code removal only), Nicholas Clark
                     qr'^c4a6f82', # Fix typos (spelling errors) in dist/*, Peter J. Acklam
                     qr'^7256076', # Move IO from ext/ to dist/, Nicholas Clark
                     qr'^adceae8', # bogus change, Rafael Garcia-Suarez
                     qr'^1be1675', # revert bogus change
                     qr'^3db8f15', # Happy chainsaw stories; The removal of the 5005 threads, H.Merijn Brand
                     qr'^231c54e', # Fix typos (spelling errors) in NetWare/* (typos in comments only), Peter J. Acklam
                     qr'copyright'i, # other copyright updates
                     qr'editor.*hints'i, # other editor hints
                   );

my $MAX_COMMITS_PER_YEAR = 5;


# === utility subs ===

sub is_real_commit
{
        my ($sha1) = @_;

        my $commit_summary = qx{git log $sha1^..$sha1 --pretty=format:"%H %s" | head -1}; chomp $commit_summary;
        return 0 if grep { $commit_summary =~ /$_/ } @SKIP_COMMITS;
        # add more funky heuristics here, eg. recognize comment-only diffs

        return 1;
}


# === prepare file list ===

# look at these files (cmdline or all interesting ones)
my @files =
 @ARGV ? @ARGV
       : grep { !$SKIPLIST{$_} }
         map { chomp; $_ }
         qx{ find . \\( -path "./ext" -o -path "./cpan" \\) -prune -type f -o -iname "*.pl" -o -iname "*.c" -o -iname "*.h" }
 ;


# === find files with Copyright lines, extract greatest year ===

my %generator;
my %context;
my %copyright;
my @copyright_files;

foreach my $file (@files) {

        # --- all lines ---
        open my $F, "<", $file or next;
        my @lines = <$F>;
        close $F;

        # --- copyright lines ---
        my $hit = 0;
        my @copyright_lines =
                map { chomp; $_ }
                grep { $hit++ if      /Copyright|Relicensed/ || $hit;
                       $hit=0 if not (/Copyright|Relicensed/ || /\d{4}/ || /\bby\b/); # [sic, "Copyright" can be repeated]
                       $hit }
                @lines;

        # --- "DO NOT EDIT" lines ---
        my @do_not_edit_lines =
                map { chomp; $_ }
                grep { /This file is built by|edit.*instead/i }
                @lines;
        foreach my $edit_line (@do_not_edit_lines) {
                if ($edit_line =~ /This file is built by ([\w\/.]+)/i or $edit_line =~ /edit (.*) instead/i) {
                        my $generator_file = $1;
                        $generator_file =~ s/\.$//;
                        $generator{$file} = $generator_file;
                }
        }
        
        # --- greatest year in copyright lines ---
        my $copyright_year = 0;
        foreach my $line (@copyright_lines) {
                # possible year styles: 19xx, 2xxx, 19xx-19yy, 19xx-yy
                my (@years) = $line =~ /\b((?:\d{4}-\d{2})|19\d{2}|2\d{3})\b/g;
                $copyright_year =
                        max
                        map { s/(\d{2})\d{2}-(\d{2})/$1$2/; $_ } # normalize 19xx-yy to 19yy
                        (@years, $copyright_year);
        }
        if ($copyright_year) {
                $copyright{$file} = $copyright_year;
                $context{$file}   = \@copyright_lines;
        }
        push @copyright_files, $file if $copyright{$file};
}

# === TAP plan ===

say "1..".(2+@copyright_files); # + README + perl.c


# === explicitely check publicly visible dates ===

my $this_year = 1900 + (localtime)[5];
say "".(system("grep -q $this_year README") ? "not " : "")."ok - README checked for $this_year";
say "".(system("grep -q 'Copyright 1987-$this_year, Larry Wall' perl.c") ? "not " : "")."ok - perl.c checked for $this_year";

# === evaluate file commits in not yet copyrighted years ===

foreach my $file (@copyright_files) {
        my $cyear = $copyright{$file};
        my %new_git_years =
                map  { ($_ => 1) }
                grep { $_ ne $cyear }
                map  { my ($y) = /^(\d{4})/g; $y }
                map  { chomp; $_ }
                map  { my ($commit, $date) = split(/ /, $_); $date }
                grep { my ($commit, $date) = split(/ /, $_); is_real_commit($commit) }
                qx{git log --after="$cyear-12-31" --pretty=format:"%h %ci" $file};
        my @new_git_years = sort keys %new_git_years;

        my @commits;

 YEAR:
        # get commits in relevant missing years
        foreach my $y (reverse @new_git_years) {
                my $after  = sprintf("%d-01-01", $y);
                my $before = sprintf("%d-01-01", $y+1);
                my $cmd = qq{git log --no-merges --date-order --before="$before 00:00" --after="$after 00:00" --pretty=format:"%h" $file};
                my @c = map { chomp; $_ } qx{$cmd};

                my $commit_counter = 0;
        COMMIT:
                # only a few interesting commits per year
                foreach (@c) {
                        next COMMIT unless is_real_commit($_);
                        $commit_counter++ ;
                        next YEAR unless $commit_counter <= $MAX_COMMITS_PER_YEAR;
                        unshift @commits, $_;
                }
        }

        my $generator_text = $generator{$file} ? " # TODO generated by ".$generator{$file} : "";
        # show overview on problematic files
        if (@commits) {
                say "";
                say "not ok - $file$generator_text";
                say "#";
                say "# copyright: $cyear";
                say "# changes:   ", join(", ", @new_git_years);
                say "# context:   ", join("\n#            ", @{$context{$file}});
                foreach my $c (reverse @commits) {
                        my ($details) = map { chomp; s/^(\w+: \(\d{4}-\d{2}-\d{2})[^)]*(.*)/$1$2/; $_ } qx{git log --format="%h: (%ci) - %an - %s" $c^..$c};
                        say "# $details";
                }
                say "\n";
        } else {
                say "ok - $file";
        }
}

# exceptions/special cases:
# DONE perl.c - only the first C
# DONE ./mint/pwd.c
# DONE embed.pl - covered via generated files
# DONE malloc.c - 2-digit years
# DONE TAP "not ok" on perl.c and README, everything else "ok # TODO"
# ----
# TODO --before/--after does not work!
# TODO opcode.pl - covered via generated files
# TODO DO_NOT_EDIT should point to generator

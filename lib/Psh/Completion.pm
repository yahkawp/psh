package Psh::Completion;

use strict;
use vars qw($VERSION %custom_completions);

use Cwd;
use Cwd 'chdir';
use Psh::Util ':all';
use Psh::Util qw(starts_with ends_with);

$VERSION = do { my @r = (q$Revision$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; # must be all one line, for MakeMaker

my @user_completions;
my $APPEND="not_implemented";
my $EMPTY_AC='';
my $GNU=0;
my $ac; # character to append

%custom_completions= ();

@Psh::bookmarks=('http://','ftp://');
@Psh::netprograms=('ping','ssh','telnet','ftp','ncftp','traceroute',
			  'netscape','lynx','mozilla','wget');

sub init
{
	@user_completions= ();

	# TODO: Portability ?
	setpwent;
	while( my ($name)= getpwent) {
		push(@user_completions,'~'.$name);
	}
	endpwent;

	my $attribs=$Psh::term->Attribs;

	# The following is ridiculous, but....
	if( $Psh::term->ReadLine eq "Term::ReadLine::Perl") {
		$APPEND='completer_terminator_character';
	} elsif( $Psh::term->ReadLine eq "Term::ReadLine::Gnu") {
		$GNU=1;
		$APPEND='completion_append_character';
		$EMPTY_AC="\0";
	}

	# Wow, both ::Perl and ::Gnu understand it
	my $word_break=" \\\n\t\"&{('`\$\%\@~<>=;|/";
	$attribs->{special_prefixes}= "\$\%\@\~\&";
	$attribs->{word_break_characters}= $word_break;
	$attribs->{completer_word_break_characters}= $word_break ;
}

sub cmpl_bookmarks
{
	my ($text, $prefix)= @_;
	my $length=length($prefix);
	return map { substr($_,$length) }
	         grep { starts_with($_,$prefix.$text) } @Psh::bookmarks;
}


# Returns a list of possible file completions
sub cmpl_filenames
{
	my $text= shift;
	my @result= glob "$text*";
	if( $ENV{FIGNORE}) {
		my @ignore= split(':',$ENV{FIGNORE});
		@result= grep {
			my $item= $_;
			my $result= ! grep { ends_with($item,$_) } @ignore;
			$result;
		} @result;
	}

	$ac='/' if(@result==1 && -d $result[0]);

	foreach (@result) {
		if( m|/([^/]+$)| ) {
			$_=$1;
		}
	}
	return @result;
}


# Returns an array with possible username completions
sub cmpl_usernames
{
	my $text= shift;
	my @result= grep { starts_with($_,$text) } @user_completions;
	return @result;
}


#
# Tries to find executables for possible completions
# TODO: This is sloooow... but probably not only because
# of searching the whole path but also because of the way
# Term::ReadLine::Gnu works... hmm
#

sub cmpl_executable
{
	my $cmd= shift;
	my $old_cwd= $ENV{PWD};
	my @result = ();

	local $^W= 0;

	which($cmd);
	# set up absed_path if not already set and check
	
	foreach my $dir (@Psh::absed_path) {
		CORE::chdir $dir;
		push( @result, grep { -x && ! -d } glob "$cmd*" );
	}	
	CORE::chdir $old_cwd;
	return @result;
}


#
# Completes perl symbols
#
# TODO: Also complete package variables and package names
#
sub cmpl_symbol
{
	my $text= shift;
	my @result=();

	local $^W= 0;

	return () if ! $text=~ /^[\$\%\&\@][a-zA-Z0-9_\:]*$/go;

	my $package= 'main::';
	my $strip_package= 1;

	if( $text=~ /^([\$\%\&\@])([a-zA-Z0-9_\:]+\:\:)([a-zA-Z0-9_]*)$/) {
		$package= $2;
		$strip_package= 0;
		$text= $1.$3;
	}

	my (@tmp, @sym);
	{
		no strict qw(refs);
		@sym = keys %{*{$package}};
	}
	
	for my $sym (sort @sym) {
		next unless $sym =~ m/^[a-zA-Z]/; # Skip some special variables
		next if     $sym =~ m/::$/ && length($text)==1;
            # Skip all package hashes if only $, %, @ etc. was
		    # specified because we do not want to display all package names
		{
			no strict qw(refs);
			push @tmp, "\$$sym" if
				ref *{"$package$sym"}{SCALAR} eq 'SCALAR';
			push @tmp,  "\@$sym" if
				ref *{"$package$sym"}{ARRAY}  eq 'ARRAY';
			push @tmp,   "\%$sym" if
				ref *{"$package$sym"}{HASH}   eq 'HASH';
			push @tmp,   "\&$sym" if
				ref *{"$package$sym"}{CODE}   eq 'CODE';
		}
	}
	foreach my $tmp (@tmp) {
		my $firstchar=substr($tmp,0,1);
		my $rest=substr($tmp,1);

		# Hack Alert ;-)
		next if(! eval "defined($firstchar$package$rest)" &&
				! eval "tied($firstchar$package$rest)" &&
				$rest ne "ENV" && $rest ne "INC" && $rest ne "SIG" &&
				$rest ne "ARGV" && !($rest=~ /::$/) );
		if( starts_with($tmp,$text)) {
			if( $strip_package) {
				push @result, $firstchar.$rest;
			} else {
				push @result, $firstchar.$package.$rest;
			}
		}
	}
	$ac=$EMPTY_AC if @result;
	$ac='(' if @result==1 && substr($result[0],0,1) eq '&';
	return @result;
}

#
# Completes key names for Perl hashes
#
sub cmpl_hashkeys {
	my( $varname, $keystart)= @_;
	my $package='main::';
	if( $varname=~ /^[\$]([a-zA-Z0-9_\:]+\:\:)([a-zA-Z0-9_]*)$/) {
		$package= $2;
		$varname= $3;
	}
	{
		no strict 'refs';
		if( eval "\%$package$varname") {
			my $var= *{"$package$varname"}{HASH};
			$ac='} ';
			return grep { starts_with($_,$keystart) } keys %$var;
		}
	}
	return ();
}

#
# completion(text,line,start,end)
#
# Main Completion function
#

sub completion
{
	my ($text, $line, $start) = @_;
	my $attribs               = $Psh::term->Attribs;
	my (@tmp, $tmp);

	my $startchar= substr($line, $start, 1);
	my $starttext= substr($line, 0, $start);

	$ac=' ';

	if ($startchar eq '~' &&
	    !($text=~/\//)) {
		# after ~ try username completion
		@tmp= cmpl_usernames($text);
		$ac="/" if @tmp;
	} elsif( $startchar eq "\$" || $startchar eq "\@" ||
			 $startchar eq "\%" || $startchar eq "\&" ) {
		# probably a perl variable/function ?
		@tmp= cmpl_symbol($text);
	} elsif( ($starttext =~ /^\$([a-zA-Z0-9_\:]+)\{$/) ||
			 ($starttext =~ /\s\$([a-zA-Z0-9_\:]+)\{$/)) {
		# a construct like: "$ENV{"
		@tmp= cmpl_hashkeys($1,$text);
	} elsif( ($starttext =~ /^\s*$/ ||
			  $starttext =~ /[\|\`]\s*$/ ) &&
			 !( $text =~ /\/|\.\.@/)) {
		# we have the first word in the line or a pipe sign/backtick in front
		# of the current item, so we try to complete executables
		@tmp= cmpl_executable($text);
	} elsif( @Psh::netprograms && 
			 $starttext =~ /^\s*(\S+)\s+/ && ($tmp=$1) &&
			 grep { $_ eq $tmp } @Psh::netprograms)
	{
		$starttext =~ /\s(\S*)$/;
		@tmp= cmpl_bookmarks($text,$1);
	} else {
		my $file=$text;
		if( $starttext =~ /\s(\S*)$/) {
			$file= $1.$text;
		} elsif( $starttext =~ /^(\S*)$/) {
			$file= $1.$text;
		}
		@tmp= cmpl_filenames($file);
	}

	$attribs->{$APPEND}=$ac;
	return sort @tmp;
}

1;
__END__

=head1 NAME

Psh::Completion - containing the completion routines of psh.
Currently works with Term::ReadLine::Gnu and Term::ReadLine::Psh

=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 AUTHOR

Markus Peter, warp@spin.de

=head1 SEE ALSO


=cut
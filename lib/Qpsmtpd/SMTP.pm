package Qpsmtpd::SMTP;
use Qpsmtpd;
@ISA = qw(Qpsmtpd);

package Qpsmtpd::SMTP;
use strict;
use Carp;

use Qpsmtpd::Connection;
use Qpsmtpd::Transaction;
use Qpsmtpd::Plugin;
use Qpsmtpd::Constants;

use Mail::Address ();
use Mail::Header ();
use IPC::Open2;
use Data::Dumper;
use POSIX qw(strftime);
use Net::DNS;

# $SIG{ALRM} = sub { respond(421, "Game over pal, game over. You got a
# timeout; I just can't wait that long..."); exit };

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my %args = @_;

  my $self = bless ({ args => \%args }, $class);

  my (@commands) = qw(ehlo helo rset mail rcpt data help vrfy noop quit);
  my (%commands); @commands{@commands} = ('') x @commands;
  # this list of valid commands should probably be a method or a set of methods
  $self->{_commands} = \%commands;

  $self;
}



sub dispatch {
  my $self = shift;
  my ($cmd) = lc shift;

  #$self->respond(553, $state{dnsbl_blocked}), return 1
  #  if $state{dnsbl_blocked} and ($cmd eq "rcpt");

  $self->respond(500, "Unrecognized command"), return 1
    if ($cmd !~ /^(\w{1,12})$/ or !exists $self->{_commands}->{$1});
  $cmd = $1;

  if (1 or $self->{_commands}->{$cmd} and $self->can($cmd)) {
    my ($result) = eval { $self->$cmd(@_) };
    $self->log(0, "XX: $@") if $@;
    return $result if defined $result;
    return $self->fault("command '$cmd' failed unexpectedly");
  }

  return;
}

sub fault {
  my $self = shift;
  my ($msg) = shift || "program fault - command not performed";
  print STDERR "$0[$$]: $msg ($!)\n";
  return $self->respond(451, "Internal error - try again later - " . $msg);
}


sub start_conversation {
    my $self = shift;
    # this should maybe be called something else than "connect", see
    # lib/Qpsmtpd/TcpServer.pm for more confusion.
    my ($rc, $msg) = $self->run_hooks("connect");
    if ($rc != DONE) {
      $self->respond(220, $self->config('me') ." ESMTP qpsmtpd "
		     . $self->version ." ready; send us your mail, but not your spam.");
    }
}

sub transaction {
  my $self = shift;
  return $self->{_transaction} || $self->reset_transaction();
}

sub reset_transaction {
  my $self = shift;
  return $self->{_transaction} = Qpsmtpd::Transaction->new();
}


sub connection {
  my $self = shift;
  return $self->{_connection} || ($self->{_connection} = Qpsmtpd::Connection->new());
}


sub helo {
  my ($self, $hello_host, @stuff) = @_;
  my $conn = $self->connection;
  return $self->respond (503, "but you already said HELO ...") if $conn->hello;

  $conn->hello("helo");
  $conn->hello_host($hello_host);
  $self->transaction;
  $self->respond(250, $self->config('me') ." Hi " . $conn->remote_info . " [" . $conn->remote_ip ."]; I am so happy to meet you.");
}

sub ehlo {
  my ($self, $hello_host, @stuff) = @_;
  my $conn = $self->connection;
  return $self->respond (503, "but you already said HELO ...") if $conn->hello;

  $conn->hello("ehlo");
  $conn->hello_host($hello_host);
  $self->transaction;

  $self->respond(250,
		 $self->config("me") . " Hi " . $conn->remote_info . " [" . $conn->remote_ip ."]",
		 "PIPELINING",
		 "8BITMIME",
		 ($self->config('databytes') ? "SIZE ". ($self->config('databytes'))[0] : ()),
		);
}

sub mail {
  my $self = shift;
  return $self->respond(501, "syntax error in parameters") if !$_[0] or $_[0] !~ m/^from:/i;

  # -> from RFC2821
  # The MAIL command (or the obsolete SEND, SOML, or SAML commands)
  # begins a mail transaction.  Once started, a mail transaction
  # consists of a transaction beginning command, one or more RCPT
  # commands, and a DATA command, in that order.  A mail transaction
  # may be aborted by the RSET (or a new EHLO) command.  There may be
  # zero or more transactions in a session.  MAIL (or SEND, SOML, or
  # SAML) MUST NOT be sent if a mail transaction is already open,
  # i.e., it should be sent only if no mail transaction had been
  # started in the session, or it the previous one successfully
  # concluded with a successful DATA command, or if the previous one
  # was aborted with a RSET.

  # sendmail (8.11) rejects a second MAIL command.

  # qmail-smtpd (1.03) accepts it and just starts a new transaction.
  # Since we are a qmail-smtpd thing we will do the same.

  $self->reset_transaction;

  unless ($self->connection->hello) {
    return $self->respond(503, "please say hello first ...");
  }
  else {
    my $from_parameter = join " ", @_;
    $self->log(2, "full from_parameter: $from_parameter");
    my ($from) = ($from_parameter =~ m/^from:\s*(\S+)/i)[0];
    warn "$$ from email address : [$from]\n";
    if ($from eq "<>" or $from =~ m/\[undefined\]/) {
      $from = Mail::Address->new("<>");
    } 
    else {
      $from = (Mail::Address->parse($from))[0];
    }
    return $self->respond(501, "could not parse your mail from command") unless $from;

    my ($rc, $msg) = $self->run_hooks("mail", $from);
    if ($rc == DONE) {
      return 1;
    }
    elsif ($rc == DENY) {
      $msg ||= $from->format . ', denied';
      $self->log(2, "deny mail from " . $from->format . " ($msg)");
      $self->respond(550, $msg);
    }
    elsif ($rc == DENYSOFT) {
      $msg ||= $from->format . ', temporarily denied';
      $self->log(2, "denysoft mail from " . $from->format . " ($msg)");
      $self->respond(450, $msg);
    }
    else { # includes OK
      $self->log(2, "getting mail from ".$from->format);
      $self->respond(250, $from->format . ", sender OK - how exciting to get mail from you!");
      $self->transaction->sender($from);
    }
  }
}

sub rcpt {
  my $self = shift;
  return $self->respond(501, "syntax error in parameters") unless $_[0] and $_[0] =~ m/^to:/i;
  return $self->respond(503, "Use MAIL before RCPT") unless $self->transaction->sender;

  my ($rcpt) = ($_[0] =~ m/to:(.*)/i)[0];
  $rcpt = $_[1] unless $rcpt;
  $rcpt = (Mail::Address->parse($rcpt))[0];

  return $self->respond(501, "could not parse recipient") unless $rcpt;

  my ($rc, $msg) = $self->run_hooks("rcpt", $rcpt);
  if ($rc == DONE) {
    return 1;
  }
  elsif ($rc == DENY) {
    $msg ||= 'relaying denied';
    $self->respond(550, $msg);
  }
  elsif ($rc == DENYSOFT) {
    $msg ||= 'relaying denied';
    return $self->respond(550, $msg);
  }
  elsif ($rc == OK) {
    $self->respond(250, $rcpt->format . ", recipient ok");
    return $self->transaction->add_recipient($rcpt);
  }
  else {
    return $self->respond(450, "Could not determine of relaying is allowed");
  }
  return 0;
}



sub help {
  my $self = shift;
  $self->respond(214, 
	  "This is qpsmtpd " . $self->version,
	  "See http://develooper.com/code/qpsmtpd/",
	  'To report bugs or send comments, mail to <ask@perl.org>.');
}

sub noop {
  my $self = shift;
  warn Data::Dumper->Dump([\$self], [qw(self)]);
  $self->respond(250, "OK");

}

sub vrfy {
  shift->respond(252, "Just try sending a mail and we'll see how it turns out ...");
}

sub rset {
  my $self = shift;
  $self->reset_transaction;
  $self->respond(250, "OK");
}

sub quit {
  my $self = shift;
  my ($rc, $msg) = $self->run_hooks("quit");
  if ($rc != DONE) {
    $self->respond(221, $self->config('me') . " closing connection. Have a wonderful day.");
  }
  $self->disconnect();
}

sub disconnect {
  my $self = shift;
  $self->run_hooks("disconnect");
}

sub data {
  my $self = shift;
  $self->respond(503, "MAIL first"), return 1 unless $self->transaction->sender;
  $self->respond(503, "RCPT first"), return 1 unless $self->transaction->recipients;
  $self->respond(354, "go ahead");
  my $buffer = '';
  my $size = 0;
  my $i = 0;
  my $max_size = ($self->config('databytes'))[0] || 0;  # this should work in scalar context
  my $blocked = "";
  my %matches;
  my $in_header = 1;
  my $complete = 0;

  $self->log(6, "max_size: $max_size / size: $size");

  my $header = Mail::Header->new(Modify => 0, MailFrom => "COERCE");

  my $timeout = $self->config('timeout');

  while (<STDIN>) {
    $complete++, last if $_ eq ".\r\n";
    $i++;
    $self->respond(451, "See http://develooper.com/code/qpsmtpd/barelf.html"), exit
      if $_ eq ".\n";
    # add a transaction->blocked check back here when we have line by line plugin access...
    unless (($max_size and $size > $max_size)) {
      s/\r\n$/\n/;
      if ($in_header and m/^\s*$/) {
	$in_header = 0;
	my @header = split /\n/, $buffer;

	# ... need to check that we don't reformat any of the received lines.
	#
	# 3.8.2 Received Lines in Gatewaying
	#   When forwarding a message into or out of the Internet environment, a
	#   gateway MUST prepend a Received: line, but it MUST NOT alter in any
	#   way a Received: line that is already in the header.

	$header->extract(\@header);
	$buffer = "";

	# FIXME - call plugins to work on just the header here; can
	# save us buffering the mail content.

      }

      if ($in_header) {
	$buffer .= $_;  
      }
      else {
	$self->transaction->body_write($_);
      }

      $size += length $_;
    }
    #$self->log(5, "size is at $size\n") unless ($i % 300);

    alarm $timeout;
  }

  $self->log(6, "max_size: $max_size / size: $size");

  $self->transaction->header($header);

  $header->add("Received", "from ".$self->connection->remote_info 
	       ." (HELO ".$self->connection->hello_host . ") (".$self->connection->remote_ip 
	       . ") by ".$self->config('me')." (qpsmtpd/".$self->version
	       .") with SMTP; ". (strftime('%Y-%m-%d %TZ', gmtime)),
	       0);

  # if we get here without seeing a terminator, the connection is
  # probably dead.
  $self->respond(451, "Incomplete DATA"), return 1 unless $complete;

  #$self->respond(550, $self->transaction->blocked),return 1 if ($self->transaction->blocked);
  $self->respond(552, "Message too big!"),return 1 if $max_size and $size > $max_size;

  my ($rc, $msg) = $self->run_hooks("data_post");
  if ($rc == DONE) {
    return 1;
  }
  elsif ($rc == DENY) {
    $self->respond(552, $msg || "Message denied");
  }
  elsif ($rc == DENYSOFT) {
    $self->respond(452, $msg || "Message denied temporarily");
  } 
  else {
    $self->queue($self->transaction);    
  }

  # DATA is always the end of a "transaction"
  return $self->reset_transaction;

}

sub queue {
  my ($self, $transaction) = @_;

  # these bits inspired by Peter Samuels "qmail-queue wrapper"
  pipe(MESSAGE_READER, MESSAGE_WRITER) or fault("Could not create message pipe"), exit;
  pipe(ENVELOPE_READER, ENVELOPE_WRITER) or fault("Could not create envelope pipe"), exit;

  my $child = fork();

  not defined $child and fault(451, "Could not fork"), exit;

  if ($child) {
    # Parent
    my $oldfh = select(MESSAGE_WRITER); $| = 1; 
                select(ENVELOPE_WRITER); $| = 1;
    select($oldfh);

    close MESSAGE_READER  or fault("close msg reader fault"),exit;
    close ENVELOPE_READER or fault("close envelope reader fault"), exit;

    $transaction->header->add("X-SMTPD", "qpsmtpd/".$self->version.", http://develooper.com/code/qpsmtpd/");

    $transaction->header->print(\*MESSAGE_WRITER);
    $transaction->body_resetpos;
    while (my $line = $transaction->body_getline) {
      print MESSAGE_WRITER $line;
    }
    close MESSAGE_WRITER;

    my @rcpt = map { "T" . $_->address } $transaction->recipients;
    my $from = "F".($transaction->sender->address|| "" );
    print ENVELOPE_WRITER "$from\0", join("\0",@rcpt), "\0\0"
      or respond(451,"Could not print addresses to queue"),exit;
    
    close ENVELOPE_WRITER;
    waitpid($child, 0);
    my $exit_code = $? >> 8;
    $exit_code and respond(451, "Unable to queue message ($exit_code)"), exit;
    $self->respond(250, "Queued.");
  }
  elsif (defined $child) {
    # Child
    close MESSAGE_WRITER or die "could not close message writer in parent";
    close ENVELOPE_WRITER or die "could not close envelope writer in parent";
    
    open(STDIN, "<&MESSAGE_READER") or die "b1";
    open(STDOUT, "<&ENVELOPE_READER") or die "b2";
    
    unless (exec '/var/qmail/bin/qmail-queue') {
      die "should never be here!";
    }
  }

}


1;

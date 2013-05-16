package AnyEvent::STOMP::Client;


use strict;
use warnings;

use parent 'Object::Event';

use Carp;
use AnyEvent;
use AnyEvent::Handle;
use List::Util 'max';


our $VERSION = '0.11';


my $TIMEOUT_MARGIN = 1000;
my $EOL = chr(10);
my $NULL = chr(0);
my %ENCODE_MAP = (
    "\r" => "\\r",
    "\n" => "\\n",
    ":"  => "\\c",
    "\\" => "\\\\",
);
my %DECODE_MAP = reverse %ENCODE_MAP;


sub connect {
    my $class = shift;
    my $self = $class->SUPER::new;

    $self->{connected} = 0;
    $self->{counter} = 0;
    $self->{host} = shift || 'localhost';
    $self->{port} = shift || 61613;

    my $additional_headers = shift || {};
    my $connect_headers = {
        'accept-version' => '1.2',
        'host' => $self->{host},
        'heart-beat' => '0,0'
    };

    if (defined $additional_headers->{'heart-beat'}) {
        $connect_headers->{'heart-beat'} = $additional_headers->{'heart-beat'};
    }
    $self->{heartbeat}{config}{client} = $connect_headers->{'heart-beat'};

    if (defined $additional_headers->{'login'}
        and defined $additional_headers->{'passcode'}
    ) {
        $connect_headers->{'login'} = $additional_headers->{'login'};
        $connect_headers->{'passcode'} = $additional_headers->{'passcode'};
    }

    my $tls_ctx = shift;
    my $tls_hash = {};
    if (defined $tls_ctx) {
        $tls_hash->{tls} = 'connect';
        $tls_hash->{tls_ctx} = $tls_ctx;
    }

    $self->{handle} = AnyEvent::Handle->new(
        connect => [$self->{host}, $self->{port}],
        keep_alive => 1,
        on_connect => sub {
            $self->{connect_headers} = $connect_headers;
            $self->send_frame('CONNECT', $connect_headers);
        },
        on_connect_error => sub {
            my ($handle, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED', $self->{host}, $self->{port});
        },
        on_error => sub {
            my ($handle, $code, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED', $self->{host}, $self->{port}, $code, $message);
        },
        on_read => sub {
            $self->read_frame;
        },
        %$tls_hash,
    );

    return bless $self, $class;
}

sub disconnect {
    my $self = shift;
    $self->send_frame('DISCONNECT', {receipt => $self->get_uuid,}) if $self->is_connected;
    $self->{connected} = 0;
}

sub DESTROY {
    my $self = shift;
    $self->disconnect;
}

sub is_connected {
    return shift->{connected};
}

sub set_heartbeat_intervals {
    my $self = shift;
    $self->{heartbeat}{config}{server} = shift;

    my ($cx, $cy) = split ',', $self->{heartbeat}{config}{client};
    my ($sx, $sy) = split ',', $self->{heartbeat}{config}{server};

    if ($cx == 0 or $sy == 0) {
        $self->{heartbeat}{interval}{client} = 0;
    }
    else {
        $self->{heartbeat}{interval}{client} = max($cx, $sy);
    }

    if ($sx == 0 or $cy == 0) {
        $self->{heartbeat}{interval}{server} = 0;
    }
    else {
        $self->{heartbeat}{interval}{server} = max($sx, $cy);
    }
}

sub reset_client_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{client};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{client} = AnyEvent->timer(
        after => ($interval/1000),
        cb => sub {
            $self->send_heartbeat;
        }
    );
}

sub reset_server_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{server};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{server} = AnyEvent->timer(
        after => ($interval/1000+$TIMEOUT_MARGIN),
        cb => sub {
            $self->{connected} = 0;
            $self->event('DISCONNECTED', $self->{host}, $self->{port});
        }
    );
}

sub get_uuid {
    my $self = shift;
    return time.$self->{counter}++;
}

sub subscribe {
    my $self = shift;
    my $destination = shift;
    my $ack_mode = shift || 'auto';
    my $additional_headers = shift || {};

    unless ($ack_mode =~ m/(?:auto|client|client-individual)/) {
        croak "Invalid acknowledgement mode '$ack_mode'. "
            ."Valid modes are 'auto', 'client' and 'client-individual'."
    }
    unless (defined $destination) {
        croak "Would you mind supplying me with a destination?";
    }

    if (defined $self->{subscriptions}{$destination}) {
        carp "You already subscribed to '$destination'.";

        if ($self->handles('SUBSCRIBED')) {
            $self->event('SUBSCRIBED', $destination);
        }
    }
    else {
        my $subscription_id = shift || $self->get_uuid;
        $self->{subscriptions}{$destination} = $subscription_id;

        my $header = {
            destination => $destination,
            id => $subscription_id,
            ack => $ack_mode, 
            %$additional_headers,
        };

        if ($self->handles('SUBSCRIBED')) {
            unless (defined $header->{receipt}) {
                $header->{receipt} = $self->get_uuid;
            }

            $self->on_receipt(
                sub {
                    my ($self, $receipt_header) = @_;
                    if ($receipt_header->{'receipt-id'} == $header->{receipt}) {
                        $self->event('SUBSCRIBED', $header->{destination});
                        $self->unreg_me;
                    }
                }
            );
        }

        $self->send_frame('SUBSCRIBE', $header);
    }

    return $self->{subscriptions}{$destination};
}

sub unsubscribe {
    my $self = shift;
    my $destination = shift;
    my $additional_headers = shift || {};

    unless (defined $destination) {
        croak "Would you mind supplying me with a destination?";
    }
    unless ($self->{subscriptions}{$destination}) {
        croak "You've never subscribed to '$destination', have you?";
    }

    my $header = {
        id => $self->{subscriptions}{$destination},
        %$additional_headers,
    };

    if ($self->handles('UNSUBSCRIBED')) {
        $header->{receipt} = $self->get_uuid unless defined $header->{receipt};

        $self->on_receipt(
            sub {
                my ($self, $receipt_header) = @_;
                if ($receipt_header->{'receipt-id'} == $header->{receipt}) {
                    $self->event('UNSUBSCRIBED', $destination);
                    $self->unreg_me;
                }
            }
        );
    }

    $self->send_frame('UNSUBSCRIBE', $header);
    delete $self->{subscriptions}{$destination};
}

sub header_hash2string {
    my $header_hashref = shift;
    return join($EOL, map { "$_:$header_hashref->{$_}" } keys %$header_hashref);
}

sub header_string2hash {
    my $header_string = shift;
    my $result_hashref = {};

    foreach (split /\n/, $header_string) {
        if (m/([^\r\n:]+):([^\r\n:]*)/) {
            # Repeated Header Entries: Do not replace if it already exists
            $result_hashref->{$1} = $2 unless defined $result_hashref->{$1};
        }
    }
    
    return $result_hashref;
}

sub encode_header {
    my $header_hashref = shift;
    my $result_hashref = {};

    my $ENCODE_KEYS = '['.join('', map(sprintf('\\x%02x', ord($_)), keys(%ENCODE_MAP))).']';

    while (my ($k, $v) = each(%$header_hashref)) {
        $v =~ s/($ENCODE_KEYS)/$ENCODE_MAP{$1}/ego;
        $k =~ s/($ENCODE_KEYS)/$ENCODE_MAP{$1}/ego;
        $result_hashref->{$k} = $v;
    }

    return $result_hashref;
}

sub decode_header {
    my $header_hashref = shift;
    my $result_hashref = {};

    while (my ($k, $v) = each(%$header_hashref)) {
        if ($v =~ m/(\\.)/) {
            $v =~ s/(\\.)/$DECODE_MAP{$1}/eg || croak "Invalid header value.";
        }
        if ($k =~ m/(\\.)/) {
            $k =~ s/(\\.)/$DECODE_MAP{$1}/eg || croak "Invalid header key.";
        }
        $result_hashref->{$k} = $v;
    }

    return $result_hashref;
}

sub send_frame {
    my ($self, $command, $header_hashref, $body) = @_;

    unless ($self->is_connected or $command eq 'CONNECT') {
        croak "Have you considered connecting to a STOMP broker first before "
            ."trying to send something?";
    }

    utf8::encode($command);

    my $header;
    if ($command eq 'CONNECT') {
        $header = header_hash2string($header_hashref);
    }
    else {
        $header = header_hash2string(encode_header($header_hashref));
    }
    utf8::encode($header);

    my $frame;
    if ($command eq 'SEND') {
        $frame = $command.$EOL.$header.$EOL.$EOL.$body.$NULL;
    }
    else {
        $frame = $command.$EOL.$header.$EOL.$EOL.$NULL;
    }

    $self->event('SEND_FRAME', $frame);
    $self->{handle}->push_write($frame);
    $self->reset_client_heartbeat_timer;
}

sub send {
    my ($self, $destination, $headers, $body) = @_;

    if (defined $destination) {
        $headers->{destination} = $destination;
    }
    else {
        croak "Would you mind supplying me with a destination?";
    }

    unless (defined $headers->{'content-length'}) {
        $headers->{'content-length'} = length $body || 0;
    }

    unless (defined $headers->{'content-type'}) {
        carp "It is strongly recommended to set the 'content-type' header.";
    }

    $self->send_frame('SEND', $headers, $body);
}

sub ack {
    my ($self, $ack_id, $transaction) = @_;

    unless ($ack_id) {
        croak "I do really need the message's ack header to ACK it.";
    }
    
    my $header = {id => $ack_id,};
    $header->{transaction} = $transaction if (defined $transaction);

    $self->send_frame('ACK', $header);
}

sub nack {
    my ($self, $ack_id, $transaction) = @_;

    unless ($ack_id) {
        croak "I do really need the message's ack header to NACK it.";
    }
    
    my $header = {id => $ack_id,};
    $header->{transaction} = $transaction if (defined $transaction);

    $self->send_frame('NACK', $header);
}

sub send_heartbeat {
    my $self = shift;
    $self->{handle}->push_write($EOL);
    $self->reset_client_heartbeat_timer;
}

sub begin_transaction {
    my $self = shift;
    my $id = shift;
    my $additional_headers = shift || {};

    croak "I really need a transaction identifier here!" unless (defined $id);

    if (defined $self->{transactions}{$id}) {
        carp "You've already begun transaction '$id'";
    }
    else {
        $self->send_frame('BEGIN', {transaction => $id, %$additional_headers,});
        $self->{transactions}{$id} = 1;
    }
}

sub commit_transaction {
    my $self = shift;
    my $id = shift;
    my $additional_headers = shift || {};

    croak "I really need a transaction identifier here!" unless (defined $id);

    unless (defined $self->{transactions}{$id}) {
        carp "You've already commited transaction '$id'";
    }

    $self->send_frame('COMMIT', {transaction => $id, %$additional_headers,});
    delete $self->{transactions}{$id};
}

sub abort_transaction {
    my $self = shift;
    my $id = shift;
    my $additional_headers = shift || {};

    croak "I really need a transaction identifier here!" unless (defined $id);

    unless (defined $self->{transactions}{$id}) {
        carp "You've already commited transaction '$id'";
    }

    $self->send_frame('ABORT', {transaction => $id, %$additional_headers,});
    delete $self->{transactions}{$id};
}

sub read_frame {
    my $self = shift;
    $self->{handle}->unshift_read(
        line => sub {
            my ($handle, $command, $eol) = @_;

            $self->reset_server_heartbeat_timer;

            if ($command =~ /(CONNECTED|MESSAGE|RECEIPT|ERROR)/) {
                $command = $1;
            }
            else {
                return;
            }

            $self->{handle}->unshift_read(
                regex => qr<\r?\n\r?\n>,
                cb => sub {
                    my ($handle, $header_string) = @_;
                    my $header_hashref = header_string2hash($header_string);
                    my $args;

                    # The headers of the CONNECTED frame are not en-/decoded
                    # for backwards compatibility with STOMP 1.0
                    unless ($command eq 'CONNECTED') {
                        $header_hashref = decode_header($header_hashref);
                    }

                    if ($command =~ m/MESSAGE|ERROR/) {
                        if (defined $header_hashref->{'content-length'}) {
                            $args->{chunk} = $header_hashref->{'content-length'};
                        }
                        else {
                            $args->{regex} = qr<[^\000]*\000>;
                        }

                        $self->{handle}->unshift_read(
                            %$args,
                            cb => sub {
                                my ($handle, $body) = @_;
                                $self->event('READ_FRAME', $command, $header_hashref, $body);
                                $self->event($command, $header_hashref, $body);

                                if (defined $header_hashref->{subscription}) {
                                    $self->event(
                                        $command.'-'.$header_hashref->{subscription},
                                        $header_hashref,
                                        $body
                                    );
                                }
                            }
                        );
                    }
                    else {
                        if ($command eq 'CONNECTED') {
                            $self->{connected} = 1;
                            $self->{session} = $header_hashref->{session};
                            $self->{version} = $header_hashref->{version};
                            $self->{server} = $header_hashref->{server};

                            $self->set_heartbeat_intervals($header_hashref->{'heart-beat'});
                        }

                        $self->event('READ_FRAME', $command, $header_hashref);
                        $self->event($command, $header_hashref);
                    }
                },
            );
        },
    );
}

sub on_connected {
    return shift->reg_cb('CONNECTED', shift);
}

sub on_disconnected {
    return shift->reg_cb('DISCONNECTED', shift);
}

sub on_send_frame {
    return shift->reg_cb('SEND_FRAME', shift);
}

sub on_read_frame {
    return shift->reg_cb('READ_FRAME', shift);
}

sub on_message {
    my ($self, $cb, $destination) = @_;

    if (defined $destination) {
        croak "Would you mind supplying me with a destination?";
    }

    if (defined $destination and defined $self->{subscriptions}{$destination}) {
        return $self->reg_cb('MESSAGE-'.$self->{subscriptions}{$destination}, $cb);
    }
    else {
        return $self->reg_cb('MESSAGE', $cb);
    }
}

sub on_receipt {
    return shift->reg_cb('RECEIPT', shift);
}

sub on_error {
    return shift->reg_cb('ERROR', shift);
}

sub on_subscribed {
    return shift->reg_cb('SUBSCRIBED', shift);
}

sub on_unsubscribed {
    return shift->reg_cb('UNSUBSCRIBED', shift);
}

sub unregister_callback {
    my ($self, $guard) = @_;
    $self->unreg_cb($guard);
}

1;

__END__

=head1 NAME

AnyEvent::STOMP::Client - An event-based non-blocking STOMP 1.2 client based on
AnyEvent and Object::Event.

=head1 SYNOPSIS

  use AnyEvent::STOMP::Client;
  
  my $stomp_client = AnyEvent::STOMP::Client->connect();

  $stomp_client->on_connected(
      sub {
          my $self = shift;

          $self->subscribe('/queue/test-destination');

          $self->send(
              '/queue/test-destination',
              {'content-type' => 'text/plain',},
              "Hello World!"
          );
      }
  );

  $stomp_client->on_message(
      sub {
          my ($self, $header, $body) = @_;
          print "$body\n";
      }
  );

  AnyEvent->condvar->recv;


=head1 DESCRIPTION

AnyEvent::STOMP::Client provides a STOMP (Simple Text Oriented Messaging
Protocol) client. Thanks to AnyEvent, AnyEvent::STOMP::Client is completely
non-blocking, by making extensive use of the AnyEvent::Handle and timers (and,
under the hood, AnyEvent::Socket). Building on Object::Event,
AnyEvent::STOMP::Client implements various events (e.g. the MESSAGE event, when
a STOMP MESSAGE frame is received) and offers callbacks for these (e.g.
on_message($callback)).

=head1 METHODS

=head2 $client = connect $host, $port, $connect_headers, $tls_context

Connect to a STOMP-compatible message broker. Returns an instance of
AnyEvent::STOMP::Client.

=over

=item C<$host>

String, optional, defaults to C<localhost>. The host, where a STOMP-compatible
message broker is running.

=item C<$port>

Integer, optional, defaults to C<61613>. The TCP port we connect to. I.e. the
port where the message broker instance is listening.

=item C<$connect_headers>

Hash, optional, empty by default. May be used to add arbitrary headers to the
STOMP CONNECT frame. STOMP login headers would, for example, be supplied using
this parameter.

=item C<$tls_context>

Hash, optional, undef by default. May be used to supply a SSL/TLS context
directly to C<AnyEvent::Handle>. See L<AnyEvent::TLS> for documentation.

=back

=head3 Example

C<< my $client = AnyEvent::STOMP::Client->connect(
    '127.0.0.1',
    61614,
    {login => 'guest', passcode => 'guest'}
); >>

=head2 $client->disconnect

Sends a DISCONNECT STOMP frame to the message broker (if we are still
connected).

=head2 bool $client->is_connected

Check whether we are still connected to the broker. May only be accurate if
STOMP heart-beats are used.

=head2 $subscription_id = $client->subscribe $destination, $ack_mode, $additional_headers

Subscribe to a destination by sending a SUBSCRIBE STOMP frame to the message
broker. Returns the subscription identifier.

=over

=item C<$destination>

String, mandatory. The destination to which we want to subscribe to.

=item C<$ack_mode>

C<auto> | C<client> | C<client-individual>, optional, defaults to C<auto>.
See the STOMP documentation for further information on acknowledgement modes.

=item C<$additional_headers>

Used to pass arbitrary headers to the SUBSCRIBE STOMP frame. Broker specific
flow control parameters for example is what would want to supply here.

=back

=head2 $client->unsubscribe $destination, $additional_headers

Unsubscribe from a destination by sending an UNSUBSCRIBE STOMP frame to the
message broker.

=over

=item C<$destination>

String, mandatory. The destination from which we want to unsubscribe.

=item C<$additional_headers>

Used to pass arbitrary headers to the SUBSCRIBE STOMP frame.

=back

=head2 $client->send $destination, $headers, $body

Send a STOMP MESSAGE to the message broker.

=over

=item C<$destination>

String, mandatory. The destination to which to send the message to.

=item C<$header>

Hash, optional, empty by default. Arbitrary headers included in the MESSAGE
frame. See the STOMP documentation for supported headers.

=item C<$body>

String, optional, empty by default. The body of the message, according to the
content-type specified in the header.

=back

=head2 $client->ack $ack_id, $transaction_id

Send an ACK frame to acknowledge a received message.

=over

=item C<$ack_id>

String, mandatory. Has to match the 'ack' header of the message that is to be
acknowledged.

=item C<$transaction_id>

String, optional. A transaction identifier, if the ACK is part of a transaction.

=back

=head2 $client->nack $ack_id, $transaction_id

Send an NACK frame to NOT acknowledge a received message.

=over

=item C<$ack_id>

String, mandatory. Has to match the 'ack' header of the message that is to be
nacked.

=item C<$transaction_id>

String, optional. A transaction identifier, if the NACK is part of a
transaction.

=back

=head2 $client->begin_transaction $transaction_id, $additional_headers

Begin a STOMP transaction.

=over

=item C<$transaction_id>

String, mandatory. A unique identifier for the transaction.

=item C<$additional_headers>

Hash, optional, empty by default. Used to pass arbitrary headers to the STOMP
frame.

=back

=head2 $client->commit_transaction $transaction_id, $additional_headers

Commit a STOMP transaction.

=over

=item C<$transaction_id>

String, mandatory. A unique identifier for the transaction.

=item C<$additional_headers>

Hash, optional, empty by default. Used to pass arbitrary headers to the STOMP
frame.

=back

=head2 $client->abort_transaction $transaction_id, $additional_headers

Abort a STOMP transaction.

=over

=item C<$transaction_id>

String, mandatory. A unique identifier for the transaction.

=item C<$additional_headers>

Hash, optional, empty by default. Used to pass arbitrary headers to the STOMP
frame.

=back

=head2 Callbacks

In order for the C<AnyEvent::STOMP::Client> to be useful, callback subroutines
can be registered for the following events:

=over

=item $guard = $client->on_connected $callback

Invoked when a CONNECTED frame is received. Parameters passed to the callback:
C<$self>, C<$header_hashref>.

=item $guard = $client->on_disconnected $callback

Invoked after having successfully disconnected from a broker. I.e. when a
callback is registered for this event and the C<disconnect> subroutine is
called, then a receipt header is included in the DISCONNECT frame and the
disconnected event is fired upon receiving the receipt for the DISCONNECT frame.
Parameters passed to the callback: C<$self>, C<$host>, C<$port>.

=item $guard = $client->on_send_frame $callback

Invoked when the STOMP frame is sent. Parameters passed to the callback:
C<$self>, C<$frame> (the sent frame as string).

=item $guard = $client->on_read_frame $callback

Invoked when a STOMP frame is received (irrespective of the STOMP command).
Parameters passed to the callback: C<$self>, C<$command>, C<$header_hashref>,
C<$body> (may be C<undef>, if the frame is not specified to contain a body).

=item $guard = $client->on_message $callback

Invoked when a MESSAGE frame is received. Parameters passed to the callback:
C<$self>, C<$header_hashref>, C<$body>.

=item $guard = $client->on_receipt $callback

Invoked when a RECEIPT frame is received. Parameters passed to the callback:
C<$self>, C<$header_hashref>.

=item $guard = $client->on_error $callback

Invoked when an ERROR frame is received. Parameters passed to the callback:
C<$self>, C<$header_hashref>, C<$body>.

=item $guard = $client->on_subscribed $callback

Invoked after having successfully subscribed to a destination. Works behind the
scenes like the C<on_disconnected> described above. Parameters passed to the
callback: C<$self>, C<$destination>.

=item $guard = $client->on_unsubscribed $callback

Invoked after having successfully unsubscribed to a destination. Works behind
the scenes like the C<on_disconnected> described above. Parameters passed to the
callback: C<$self>, C<$destination>.

=back

=head3 $client->unregister_callback $guard

To unregister a previously registered callback.

=over

=item C<$guard>

The return value of one of the above on_<xyz> subroutines, identifying the
registered callback.

=back

=head1 BUGS / LIMITATIONS

=over

=item

Currently only the most recent version of STOMP, i.e. 1.2, is supported.

=back


=head1 SEE ALSO

L<AnyEvent>, L<AnyEvent::Handle>, L<AnyEvent::TLS>, L<Object::Event>,
L<STOMP 1.2 Documentation|http://stomp.github.io/stomp-specification-1.2.html>

=head1 AUTHOR

Raphael Seebacher, E<lt>raphael@seebachers.chE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by L<Open Systems AG|http://www.open.ch>. All rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

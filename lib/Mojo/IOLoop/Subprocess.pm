package Mojo::IOLoop::Subprocess;
use Mojo::Base 'Mojo::EventEmitter';

use Config;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use POSIX ();
use Storable;

has deserialize => sub { \&Storable::thaw };
has ioloop      => sub { Mojo::IOLoop->singleton };
has serialize   => sub { \&Storable::freeze };

sub pid { shift->{pid} }

sub run {
  my ($self, @args) = @_;
  $self->ioloop->next_tick(sub { $self->_start(@args) });
  return $self;
}

sub _start {
  my ($self, $child, $parent) = @_;

  # No fork emulation support
  return $self->$parent('Subprocesses do not support fork emulation')
    if $Config{d_pseudofork};

  # Pipe for subprocess communication
  return $self->$parent("Can't create pipe: $!")
    unless pipe(my $reader, my $writer);
  $writer->autoflush(1);

  # Child
  return $self->$parent("Can't fork: $!")
    unless defined(my $pid = $self->{pid} = fork);
  unless ($pid) {
    $self->ioloop->reset;
    my $results = eval { [$self->$child] } || [];
    print $writer $self->serialize->([$@, @$results]);
    POSIX::_exit(0);
  }

  # Parent
  my $me     = $$;
  my $stream = Mojo::IOLoop::Stream->new($reader)->timeout(0);
  $self->emit('spawn')->ioloop->stream($stream);
  my $buffer = '';
  $stream->on(read => sub { $buffer .= pop });
  $stream->on(
    close => sub {
      return unless $$ == $me;
      waitpid $pid, 0;
      my $results = eval { $self->deserialize->($buffer) } || [];
      $self->$parent(shift(@$results) // $@, @$results);
    }
  );
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::Subprocess - Subprocesses

=head1 SYNOPSIS

  use Mojo::IOLoop::Subprocess;

  # Operation that would block the event loop for 5 seconds
  my $subprocess = Mojo::IOLoop::Subprocess->new;
  $subprocess->run(
    sub {
      my $subprocess = shift;
      sleep 5;
      return '♥', 'Mojolicious';
    },
    sub {
      my ($subprocess, $err, @results) = @_;
      say "Subprocess error: $err" and return if $err;
      say "I $results[0] $results[1]!";
    }
  );

  # Start event loop if necessary
  $subprocess->ioloop->start unless $subprocess->ioloop->is_running;

=head1 DESCRIPTION

L<Mojo::IOLoop::Subprocess> allows L<Mojo::IOLoop> to perform computationally
expensive operations in subprocesses, without blocking the event loop.

=head1 EVENTS

L<Mojo::IOLoop::Subprocess> inherits all events from L<Mojo::EventEmitter> and
can emit the following new ones.

=head2 spawn

  $subprocess->on(spawn => sub {
    my $subprocess = shift;
    ...
  });

Emitted in the parent process when the subprocess has been spawned.

  $subprocess->on(spawn => sub {
    my $subprocess = shift;
    my $pid = $subprocess->pid;
    say "Performing work in process $pid";
  });

=head1 ATTRIBUTES

L<Mojo::IOLoop::Subprocess> implements the following attributes.

=head2 deserialize

  my $cb      = $subprocess->deserialize;
  $subprocess = $subprocess->deserialize(sub {...});

A callback used to deserialize subprocess return values, defaults to using
L<Storable>.

  $subprocess->deserialize(sub {
    my $bytes = shift;
    return [];
  });

=head2 ioloop

  my $loop    = $subprocess->ioloop;
  $subprocess = $subprocess->ioloop(Mojo::IOLoop->new);

Event loop object to control, defaults to the global L<Mojo::IOLoop> singleton.

=head2 serialize

  my $cb      = $subprocess->serialize;
  $subprocess = $subprocess->serialize(sub {...});

A callback used to serialize subprocess return values, defaults to using
L<Storable>.

  $subprocess->serialize(sub {
    my $array = shift;
    return '';
  });

=head1 METHODS

L<Mojo::IOLoop::Subprocess> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 pid

  my $pid = $subprocess->pid;

Process id of the spawned subprocess if available.

=head2 run

  $subprocess = $subprocess->run(sub {...}, sub {...});

Execute the first callback in a child process and wait for it to return one or
more values, without blocking L</"ioloop"> in the parent process. Then execute
the second callback in the parent process with the results. The return values of
the first callback and exceptions thrown by it, will be serialized with
L<Storable>, so they can be shared between processes.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut

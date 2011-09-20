package Plack::Middleware::ErrorDocument;
use strict;
use warnings;
use parent qw(Plack::Middleware);
use Plack::MIME;
use Plack::Util;
use Plack::Util::Accessor qw( subrequest );
use Data::Dumper;

use HTTP::Status qw(is_error);

sub call {
    my $self = shift;
    my $env  = shift;

    my $response;
    warn 'doing r '.$env->{PATH_INFO};
    my $r = $self->app->($env);
    my $process = sub {
        my $r = shift;
        unless (is_error($r->[0]) && exists $self->{$r->[0]}) {
            warn 'not interested';
            warn Dumper $r;
            return;
        }
        
        my $path = $self->{$r->[0]};
        if ($self->subrequest) {
            warn 'doing sub';
            for my $key (keys %$env) {
                unless ($key =~ /^psgi/) {
                    $env->{'psgix.errordocument.' . $key} = $env->{$key};
                }
            }

            # TODO: What if SCRIPT_NAME is not empty?
            $env->{REQUEST_METHOD} = 'GET';
            $env->{REQUEST_URI}    = $path;
            $env->{PATH_INFO}      = $path;
            $env->{QUERY_STRING}   = '';
            delete $env->{CONTENT_LENGTH};

            warn 'doing sub_r '.$env->{PATH_INFO};
            my $sub_r = $self->app->($env);

            if ( ref($sub_r) eq 'CODE' ) {
                warn 'sub_r is delayed';
                $response = sub {
                    my $r_starter = shift;
                    warn 'r_starter:';
                    warn Dumper $r_starter;
                    my $r_writer;
                    $sub_r->( sub {
                        my $resp = shift;
                        warn Dumper $resp;
                        if ( $resp->[0] != 200 ) {
                            warn 'ignoring sub_r';
                            $r_writer = $r_starter->($r);
                            return Plack::Util::inline_object(
                                write => sub { }, close => sub { }
                            );
                        }
                        # r writer -> sub_r writer
                        return $r_starter->([$r->[0],$resp->[1]]);
                    } );
                    warn 'got back from sub_r';
                    warn Dumper $r;
                    return $r_writer;
                };
                return;
            } else {
                warn 'sub_r is immediate';
                warn 'but r needs a writer' unless $r->[2];
                return unless $sub_r->[0] == 200;
                $response = sub {}; #Plack::Util::inline_object(write=>sub{},close=>sub{});
                $r->[1] = $sub_r->[1];
                $r->[2] = $sub_r->[2];
                return sub {};
            }
            # TODO: allow 302 here?
        } else {
            open my $fh, "<", $path or die "$path: $!";
            $r->[2] = $fh;
            my $h = Plack::Util::headers($r->[1]);
            $h->remove('Content-Length');
            $h->set('Content-Type', Plack::MIME->mime_type($path));
        }
        return;
    };
    
    my $res;
    if ( ref($r) eq 'CODE' ) {
        warn 'got delayed response, have to return delayed response to the server';
        return sub {
            my $starter = shift; # call this to get writer for server
            warn 'doo '.Dumper $starter;
            return $r->( sub { $process->(@_) || $starter->(@_) } );
        }
    } else {
        $res = $process->($r) || $r;
    }
    
    warn 'after response_cb';
    return $response || $res;
}

1;

__END__

=head1 NAME

Plack::Middleware::ErrorDocument - Set Error Document based on HTTP status code

=head1 SYNOPSIS

  # in app.psgi
  use Plack::Builder;

  builder {
      enable "Plack::Middleware::ErrorDocument",
          500 => '/uri/errors/500.html', 404 => '/uri/errors/404.html',
          subrequest => 1;
      $app;
  };

=head1 DESCRIPTION

Plack::Middleware::ErrorDocument allows you to customize error screen
by setting paths (file system path or URI path) of error pages per
status code.

=head1 CONFIGURATIONS

=over 4

=item subrequest

A boolean flag to serve error pages using a new GET sub request.
Defaults to false, which means it serves error pages using file
system path.

  builder {
      enable "Plack::Middleware::ErrorDocument",
          502 => '/home/www/htdocs/errors/maint.html';
      enable "Plack::Middleware::ErrorDocument",
          404 => '/static/404.html', 403 => '/static/403.html', subrequest => 1;
      $app;
  };

This configuration serves 502 error pages from file system directly
assuming that's when you probably maintain database etc. but serves
404 and 403 pages using a sub request so your application can do some
logic there like logging or doing suggestions.

When using a subrequest, the subrequest should return a regular '200' response.

=back

=head1 AUTHOR

Tatsuhiko Miyagawa

=head1 SEE ALSO

=cut

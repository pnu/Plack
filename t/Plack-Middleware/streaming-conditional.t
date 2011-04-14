use strict;
use warnings;
use Test::More;
use Plack::Builder;
use HTTP::Request::Common;
use Plack::Test;
use Plack::Util;

# A streaming backend. ETag is for the middleware below.
#
my $backend = sub {
    my $env = shift;
    return sub {
        my $writer = shift->( [ 200, [
            'Content-Type' => 'text/plain',
            'ETag' => 'DEADBEEF',
        ] ] );
        $writer->write($_) for ( qw( kling klang klong ) );
        $writer->close;
    };
};

# A middleware that may change the response. In this case it validates the
# request and replaces it with an empty 304 response. This is simplified
# version of the ConditionalGET.
#
my $middleware = sub { my $app = shift; sub {
    my $env = shift;
    my $res = $app->($env);
    Plack::Util::response_cb( $res, sub {
        my $res = shift;
        my $h = Plack::Util::headers($res->[1]);
        return unless $h->get('ETag') and $env->{HTTP_IF_NONE_MATCH};
        if ( $h->get('ETag') eq $env->{HTTP_IF_NONE_MATCH} ) {
            $res->[0] = 304;
            $res->[2] = [];
        }
    } );
} };

my $handler = builder {
    enable $middleware;
    $backend;
};

test_psgi $handler, sub {
    my $cb = shift;

    # Normal streaming response. Headers are inspected in the response_cb of
    # the $middleware. This happens before the streaming starts, and before
    # server even sees the response. The middleware does not change the
    # response, since there is no ETag header in the request. Works as
    # expected.
    #
    subtest 'streaming' => sub {
        my $res = $cb->( GET "/" );
        is $res->code, 200, 'Response HTTP status';
        is $res->content, 'klingklangklong', 'Response content';
    };

    # The second request fails to an internal server error. The middleware
    # sees the matching ETag, and sets the response status anb body. Adding
    # the body to the response changes the response to a normal
    # (non-streaming) response.
    #
    # From server's (or any surrounding middleware's) point of view it's now a
    # normal [304,[...],[]] ArrayRef response. Server doesn't know that the
    # response was originally a streaming response, but backend app is still
    # expecting to get a $writer.
    #
    # Server doesn't return anything, since it's a normal response, but the
    # backend app fails when trying to $writer->write().
    #
    subtest 'streaming not modified' => sub {
        my $res = $cb->( GET "/", 'If-None-Match' => 'DEADBEEF' );
        is $res->code, 500, 'Response HTTP status';
        like $res->content, qr{^Can't call method "write" on an undefined value}, 'Response content';
    };
};

# Current solution
#
# One option for the middleware is just "go away" from such responses.
# This is like the current ConditionalGET does. It just returns if reponse is
# streaming.
#
my $middleware_no_streaming = sub { my $app = shift; sub {
    my $env = shift;
    my $res = $app->($env);
    Plack::Util::response_cb( $res, sub {
        my $res = shift;
        return unless $res->[2]; # do not support streaming interface
        my $h = Plack::Util::headers($res->[1]);
        return unless $h->get('ETag') and $env->{HTTP_IF_NONE_MATCH};
        if ( $h->get('ETag') eq $env->{HTTP_IF_NONE_MATCH} ) {
            $res->[0] = 304;
            $res->[2] = [];
        }
    } );
} };

$handler = builder {
    enable $middleware_no_streaming;
    $backend;
};

test_psgi $handler, sub {
    my $cb = shift;

    # The 200 response is better, but here middleware doesn't do anything,
    # so there's not much benefit from that: you'd have to disable the
    # streaming, or buffer the stream first.
    #
    subtest 'streaming not modified' => sub {
        my $res = $cb->( GET "/", 'If-None-Match' => 'DEADBEEF' );
        is $res->code, 200, 'Response HTTP status';
        is $res->content, 'klingklangklong', 'Response content';
    };
};

# The backend app is easy to modify to handle the "undef" situation, by
# adding one "return unless defined $writer" -line. The $writer is the return
# value from the server (or outer middleware). Undef doesn't mean it's an
# "undef writer" - it means that the server has seen a normal reponse and
# returns without value, as it is supposed to do.
#
# This "unless defined" check alone would be fully backwards compatible, since
# it's just a defensive additional check. However, requiring this is not part
# of the spec, so middleware (or servers) can't expect that this (setting a
# non-streaming body to a response that originally had a streaming body) would
# be handled correctly.
#
# To signal that _this_ stream producer (backend app) "is prepared", it could
# $env->{'psgi.streaming.conditional'} as a flag.
#
my $backend_with_check = sub {
    my $env = shift;
    return sub {
        $env->{'psgi.streaming.conditional'} = Plack::Util::TRUE; # flag
        my $writer = shift->( [ 200, [
            'Content-Type' => 'text/plain',
            'ETag' => 'DEADBEEF',
        ] ] );
        return unless defined $writer; # prune
        $writer->write($_) for ( qw( kling klang klong ) );
        $writer->close;
    };
};

# Now the middleware can safely change the body if it sees the flag.
# If the flag is not defined, it would just "go away" (in case this is a
# streaming response).
#
my $middleware_with_check = sub { my $app = shift; sub {
    my $env = shift;
    my $res = $app->($env);
    Plack::Util::response_cb( $res, sub {
        my $res = shift;
        return unless $res->[2] or $env->{'psgi.streaming.conditional'}; # ...
        my $h = Plack::Util::headers($res->[1]);
        return unless $h->get('ETag') and $env->{HTTP_IF_NONE_MATCH};
        if ( $h->get('ETag') eq $env->{HTTP_IF_NONE_MATCH} ) {
            $res->[0] = 304;
            $res->[2] = [];
        }
    } );
} };

$handler = builder {
    enable $middleware_with_check;
    $backend_with_check;
};

test_psgi $handler, sub {
    my $cb = shift;

    subtest 'streaming' => sub {
        my $res = $cb->( GET "/" );
        is $res->code, 200, 'Response HTTP status';
        is $res->content, 'klingklangklong', 'Response content';
    };

    # Now also empty 304 works; the middleware can do it's thing.
    #
    subtest 'streaming not modified' => sub {
        my $res = $cb->( GET "/", 'If-None-Match' => 'DEADBEEF' );
        is $res->code, 304, 'Response HTTP status';
        is $res->content, '', 'Response content';
    };
};

done_testing;


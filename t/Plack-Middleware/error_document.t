use strict;
use warnings;
use FindBin;
use Test::More;
use HTTP::Request::Common;
use Plack::Test;
use Plack::Builder;

my $log;
my $handler = builder {
    enable "Plack::Middleware::ErrorDocument",
        500 => "$FindBin::Bin/errors/500.html";
    enable "Plack::Middleware::ErrorDocument",
        404 => "/errors/404.html", subrequest => 1;
    enable "Plack::Middleware::Static",
        path => qr{^/errors}, root => $FindBin::Bin;

    sub {
        my $env = shift;
        my $status = ($env->{PATH_INFO} =~ m!status/(\d+)!)[0] || 200;
        if ( $env->{PATH_INFO} =~ m!/writer! ) {
            return sub {
                my $writer = shift->(
                    [ $status, [ 'Content-Type' => 'text/plain' ] ]
                );
                $writer->write($_) for qw/kling klang klong/;
                $writer->close;
            };
        } else {
            [ $status, [ 'Content-Type' => 'text/plain' ], [ "Error: $status" ] ];
        }
    };
};

test_psgi app => $handler, client => sub {
    my $cb = shift;
    {
        my $res = $cb->(GET "http://localhost/");
        is $res->code, 200;

        $res = $cb->(GET "http://localhost/writer");
        is $res->code, 200;
        like $res->content, qr/klingklangklong/;

        $res = $cb->(GET "http://localhost/status/500");
        is $res->code, 500;
        like $res->content, qr/fancy 500/;

        $res = $cb->(GET "http://localhost/status/500/writer");
        is $res->code, 500;
        like $res->content, qr/fancy 500/;

        $res = $cb->(GET "http://localhost/status/404");
        is $res->code, 404;
        like $res->header('content_type'), qr!text/html!;
        like $res->content, qr/fancy 404/;

        $res = $cb->(GET "http://localhost/status/404/writer");
        is $res->code, 404;
        like $res->header('content_type'), qr!text/html!;
        like $res->content, qr/fancy 404/;
    }
};

done_testing;

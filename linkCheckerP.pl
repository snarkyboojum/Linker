use strict;
use warnings;

use HTML::LinkExtor;
use LWP::UserAgent;
use URI::URL;

use IPC::ShareLite;
use Storable qw(freeze thaw);

use Data::Dumper;


my $VERBOSE = 0;

my $MAX_PROCESSES = 16;
my $DOMAIN_FILTER = '((http|https)://)?' . url($ARGV[0])->host;

# shared memory segment for all links
my $linkStore = IPC::ShareLite->new(
    -key     => 1978,
    -create  => 'yes',
    -destroy => 'no'
    ) or die $!;

# init link store - do we need to do this?
$linkStore->store( freeze({}) );


# shared memory segment for links to visit
my $visitStore = IPC::ShareLite->new(
    -key     => 1979,
    -create  => 'yes',
    -destroy => 'no'
    ) or die $!;

# init visitable store - do we need to do this?
$visitStore->store( freeze([]) );

# build one user agent
my $agent = LWP::UserAgent->new();



eval { main(); };

if ($@) {
    print(STDERR "ERROR: [$@]\n")
}


# this should be atomic
#
sub storeLink {
    my ($url, $referrer) = (shift, shift);

    if ($linkStore->version) {

        #$linkStore->lock;
        my $linkMap = thaw($linkStore->fetch);
    
        if (! exists $linkMap->{$url} ) {
            $linkMap->{$url} = {'referrer' => $referrer, 'status' => undef};
            $linkStore->store( freeze($linkMap) );

            my $visitList = thaw($visitStore->fetch);
            push(@$visitList, $url);
            $visitStore->store( freeze($visitList) );
        }
        else {
            print("Already visited: [$url]\n from: [$linkMap->{$url}->{'referrer'}]\n") if $VERBOSE;
        }

        # FIXME: push referrers onto list for $url
        #else {
        #    push($linkMap->{$url}, $referrer);
        #}

        #$linkStore->unlock;

    }
}


sub getLinksToVisit {
    my $linksToVisit = thaw( $visitStore->fetch );

    return $linksToVisit;
    
}


sub getLinksFromStore {
    my $linkMap = thaw( $linkStore->fetch );

    return keys %$linkMap;
}


sub popVisitLink {

    #$visitStore->lock;
    my $links = thaw( $visitStore->fetch );

    my $url;

    if (scalar @$links) {
        $url = pop @$links;    
        $visitStore->store( freeze($links) );
    }
    else {
        return undef;
    }

    #$visitStore->unlock;

    return $url;
}


sub main {

    my $urlRoot = $ARGV[0];
    my @pids    = ();
    $| = 1;

    storeLink($urlRoot, '');
    storeLink($urlRoot, '');

    while ( scalar @{getLinksToVisit()} ) {
        
        my $numLinks = scalar @{getLinksToVisit()};
        print("Links to visit: [$numLinks]\n");

        my $processLimit = $MAX_PROCESSES; 

        if (scalar @{getLinksToVisit()} < $MAX_PROCESSES) {
            $processLimit = scalar @{getLinksToVisit()};
        }

        for (my $i = 0; $i < $processLimit; $i++) {
            my $url = popVisitLink();

            my $pid = fork();

            # track our child pids
            if ($pid) {
                push(@pids, $pid);
    
            }
            # call getLinks from child processes
            elsif ($pid == 0) {

                foreach my $link (getLinks($url)) {
                    if ($link !~ m{^$DOMAIN_FILTER}i) {
                        print("Skipping URL: [$link]\n") if $VERBOSE;
                        next;
                    }
                    storeLink($link, $url);
                }

                exit(0);
            }
            else {
                die("Couldn't fork: [$!]");
            }
        }
        
        foreach my $pid (@pids) {
            waitpid($pid, 0);
        }

        # FIXME: do this more efficiently?
        @pids = [];
    }

    #print Dumper( thaw($linkStore->fetch) );
    print Dumper( keys %{thaw($linkStore->fetch)} );

}


sub getLinks {
    my $url   = shift;
    my @links = ();

    my $response = $agent->get($url);
    my $contentType = $response->header('Content-Type');

    if ($response->is_success) {
    if (defined $contentType && $contentType =~ m|text/html|) {
        my $content = $response->content;
        my $base    = $response->base;

        print("Getting links for url: [$url]\n") if $VERBOSE;
        
        # extract links out of content
        my $parser = HTML::LinkExtor->new(
            sub {
                my ($tag, %attr, $links) = (shift, shift, shift);

                return if ($tag ne 'a');
                push(@links, map { cleanUrl( url($_, $base)->abs ); } values %attr);
                }
            );

        $parser->parse($content);
    }
    }
    return @links;
}


sub cleanUrl {
    my $url = shift;

    $url =~ s|#[^#]*$||;
    return $url;
}


# so we can debug multiple processes properly with perl -d ...
#
sub DB::get_fork_TTY {
    open XT, q[3>&1 xterm -title 'Forked Perl debugger' -e bash -c 'tty +1>&3; sleep 10000000' |];
    $DB::fork_TTY = <XT>;
    chomp $DB::fork_TTY;
}

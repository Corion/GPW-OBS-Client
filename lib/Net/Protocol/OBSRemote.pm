package Net::Protocol::OBSRemote;
use 5.020;
use warnings;
use Digest::SHA 'sha256_base64';
#use MIME::Base64 'decode_base64';
use Moo 2;
use feature 'signatures';
no warnings 'experimental::signatures';

has id => (
    is => 'rw',
    default => 1,
);

sub nextMessage($self,$msg) {
    my $id = $self->{id}++;
    $msg->{"message-id"} = "$id";
    return $msg;
}

sub GetVersion($self) {
    return $self->nextMessage({'request-type' => 'GetVersion'})
}

sub GetAuthRequired($self) {
    return $self->nextMessage({'request-type' => 'GetAuthRequired'})
}

sub Authenticate($self,$password,$saltMsg) {
    my $hash = sha256_base64( $password, $saltMsg->{salt} );
    while( length( $hash )% 4) {
        $hash .= '=';
    };
    my $auth_response = sha256_base64( $hash, $saltMsg->{challenge} );
    while( length( $auth_response ) % 4) {
        $auth_response .= '=';
    };

    my $payload = {
        'request-type' => 'Authenticate',
        'auth' => $auth_response,
    };
    return $self->nextMessage($payload)
}

sub SetTextFreetype2Properties($self,%properties) {
    return $self->nextMessage({
        'request-type' => 'SetTextFreetype2Properties',
        %properties,
    })
};

sub GetSourceSettings($self,%sourceInfo) {
    return $self->nextMessage({
        'request-type' => 'GetSourceSettings',
        %sourceInfo,
    })
};

1;

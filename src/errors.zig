pub const NetError = error{
    InvalidUrl,
    DnsFailed,
    ConnectionRefused,
    Timeout,
    CertInvalid,
    TlsError,
    TransferFailed,
};

pub const ParseError = error{MalformedDocument};
pub const NavError = NetError || ParseError;
pub const StoreError = error{CrossOriginDenied};

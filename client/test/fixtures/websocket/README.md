Synthetic localhost TLS certificate and private key for offline transport tests only.
Generated with OpenSSL; never used for a school, account, production service, or signing.

The `.txt` files contain PEM data. Only the test-injected trust store accepts the
certificate; production uses the system trust store. They are disposable fixtures.

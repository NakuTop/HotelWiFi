All default tests use synthetic network samples, URLProtocol, and in-memory configuration backends.
They never call SystemConfigurationBackend.compareAndSet, CoreWLAN association, WiFi power, or DHCP renewal.
Real network writes require the separate opt-in procedure in Docs/REAL_WRITE_TESTS.md.

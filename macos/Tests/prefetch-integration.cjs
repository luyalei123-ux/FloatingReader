// The independent background loader replaces the old shared-page next/back flow.
require("./next-loader-integration.cjs");
require("fs").copyFileSync("/tmp/ReaderNextLoaderIntegration.swift", "/tmp/ReaderPrefetchIntegration.swift");

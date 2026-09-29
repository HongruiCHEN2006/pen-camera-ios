@preconcurrency import Network

enum NetworkRoutePolicy {
    static func cameraWiFiParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        return parameters
    }

    static func cloudCellularParameters() -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions,
            "http/1.1"
        )

        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options()
        )
        parameters.requiredInterfaceType = .cellular
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false
        return parameters
    }
}

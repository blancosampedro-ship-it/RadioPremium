//
//  RadioBrowserMirrors.swift
//  RadioPremium
//
//  Lista de espejos de la API de Radio Browser, para failover.
//
//  Radio Browser es un servicio gratuito mantenido por voluntarios: sus
//  servidores se caen y se saturan con frecuencia. Cuando el proxy de un
//  espejo no tiene backend vivo detrás responde `503 no available server`,
//  que es exactamente el error que veía el usuario.
//
//  La API recomienda no clavar un servidor concreto sino resolver
//  `all.api.radio-browser.info`, que apunta por DNS a un servidor vivo.
//  Aquí hacemos lo pragmático: respetamos el configurado en Secrets.plist
//  como primera opción y guardamos el resto como red de seguridad.
//
//  Ver: https://api.radio-browser.info/
//

import Foundation

enum RadioBrowserMirrors {

    /// Espejos conocidos, en orden de preferencia *después* del configurado.
    ///
    /// `all` va primero porque es el entry point recomendado por la API: no es
    /// una máquina concreta, sino un nombre DNS que resuelve a un servidor que
    /// está vivo. Los espejos nacionales van después como último recurso —
    /// algunos llevan meses caídos, pero fallan al instante (fallo de DNS o
    /// conexión rechazada), así que tenerlos en la lista no cuesta tiempo.
    static let fallbackHosts: [String] = [
        "all.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "de1.api.radio-browser.info",
        "at1.api.radio-browser.info",
        "nl1.api.radio-browser.info"
    ]

    /// Construye la lista de base URLs a probar, en orden.
    ///
    /// La configurada va siempre primera (respetamos Secrets.plist). El resto
    /// se derivan cambiando solo el host, conservando esquema y path (`/json`),
    /// y se deduplican por host para no golpear dos veces el mismo servidor.
    static func baseURLs(preferring configured: URL) -> [URL] {
        var result: [URL] = [configured]
        var seenHosts: Set<String> = [configured.host?.lowercased() ?? ""]

        for host in fallbackHosts {
            guard !seenHosts.contains(host) else { continue }
            guard var components = URLComponents(url: configured, resolvingAgainstBaseURL: false) else { continue }
            components.host = host
            guard let url = components.url else { continue }
            seenHosts.insert(host)
            result.append(url)
        }

        return result
    }
}

import Foundation

/// Embedded PWA assets.
/// GET /manifest.webmanifest → manifest (application/manifest+json)
/// GET /icon.svg → iconSVG (image/svg+xml)
enum WebAppAssets {
    static let manifest = #"""
{"id":"/","name":"WindowShare","short_name":"WindowShare","start_url":"/","scope":"/","display":"standalone","background_color":"#0e1218","theme_color":"#0e1218","icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any"}]}
"""#

    static let iconSVG = #"""
<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512"><rect width="512" height="512" rx="96" fill="#0e1218"/><rect x="96" y="128" width="320" height="256" rx="24" fill="none" stroke="#e9eef5" stroke-width="24"/><path d="M108 200h296" stroke="#e9eef5" stroke-width="24"/></svg>
"""#
}

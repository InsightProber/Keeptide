import XCTest
@testable import Keeptide

final class LinkAddressTests: XCTestCase {
    func testWebLinksAreLoaded() {
        for text in [
            "https://www.example.com/", "http://example.com", "https://example.com/a/b?q=swift&page=2#top",
            "  https://example.com/path\n", "HTTPS://Example.COM/Path", "https://example.com:8443/",
            "https://xn--fsqu00a.xn--0zwm56d/", "https://例子.测试/",
            // Parameter names that only look like a secret's.
            "https://example.com/search?keyword=swift", "https://example.com/?monkey=1",
            "https://mail.example.com/?authuser=0",
            "https://example.com/watch?codec=h264", "https://example.com/?signup=1&passage=2",
            // A secret's name as a value, or in the path, is not a parameter.
            "https://example.com/search?q=token", "https://example.com/?sort=key",
            "https://example.com/docs/token-auth",
            "https://example.com/page#section-2",
            // A code that is a country's, a postal one, a colour or an offer is no secret.
            "https://shop.example.com/?countryCode=US&zip_code=94105&colorDisplayCode=09&promo_code=SPRING",
            "https://example.com/?postal_code=94105&currency_code=EUR&status_code=200&error_code=404",
            "https://www.amazon.com/dp/B000000000?tag=example-20&linkCode=ll1&th=1",
            "https://hotels.example.com/?propertyCode=NYC12&rateCode=BAR&sizeCode=M&storeCode=12",
            // A link that carries another, as a click tracker's does, when neither holds a secret.
            "https://nam12.safelinks.example.com/?url=https%3A%2F%2Fwww.example.com%2Farticle&data=05",
            "https://www.google.com/url?q=https://example.com/&sa=D",
            "https://example.com/login?next=/account/settings",
            // Nor is a word that only happens to begin with a token's first letters.
            "https://example.com/reports/surveyJanuary2024.findings.pdf",
        ] {
            if case .failure(let refusal) = LinkAddress.loadable(text) { XCTFail("\(text) is refused: \(refusal)") }
        }
    }

    func testOnlyOneWebAddressIsLoaded() {
        for text in ["ftp://example.com/", "mailto:someone@example.com", "file:///etc/hosts",
                     "javascript:void(0)", "http:example.com", "https:///path", "http://ex ample.com/",
                     "https://example.com/a b", "https://example.com/\u{0}", "", "   ", "example.com",
                     "https://example.com/\nhttps://example.org/"] {
            XCTAssertEqual(refusal(text), .notWebLink, text)
        }
    }

    func testALinkThatNamesAUserOrAPasswordIsNotLoaded() {
        for text in ["http://user:secret@example.com/", "https://user@example.com/", "http://@example.com/",
                     "https://tracker.example.com/?u=https%3A%2F%2Fuser%3Apass%40example.com%2F"] {
            XCTAssertEqual(refusal(text), .credentials, text)
        }
    }

    func testALinkToThisMacOrTheLocalNetworkIsNotLoaded() {
        for text in [
            "http://localhost/", "http://LOCALHOST:3000/", "http://localhost.:3000/", "http://app.localhost/",
            "http://printer.local/", "http://router.home.arpa/", "http://wiki.internal/", "http://nas.lan/",
            "http://server.corp/", "http://mac.home/", "http://site.test/", "http://host.localdomain/",
            "http://intranet/", "http://wiki/",
            // An IP address, written any way a browser reads one, and a public one too.
            "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.1/", "http://0x7f000001/",
            "http://0177.0.0.1/", "http://192.168.1.1/", "http://10.0.0.1:8080/", "http://8.8.8.8/",
            "http://[::1]/", "http://[fe80::1]/", "http://[2001:db8::1]:8080/",
            // A name that reads as a local one once its escapes and wide characters are undone.
            "http://%6c%6f%63%61%6c%68%6f%73%74/", "http://127。0。0。1/", "http://１２７.０.０.１/",
            "http://nas.ｌａｎ/", "http://127.0.0.0x1/", "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:192.168.1.1]/",
            // Escapes in a name, which a browser undoes and then makes narrow; any name written with them.
            "http://192.168.1.%EF%BC%91/", "http://nas.%EF%BD%8C%EF%BD%81%EF%BD%8E/",
            "http://printer.%EF%BD%8C%EF%BD%8F%EF%BD%83%EF%BD%81%EF%BD%8C/", "http://%31%32%37.0.0.1/",
            "http://ex%41mple.com/", "http://nas.private/",
            // A link to the local network carried by another: as a value, escaped twice, given after another value,
            // or as a name, as some redirectors write it.
            "https://tracker.example.com/?u=http%3A%2F%2F192.168.1.1%2Fadmin",
            "https://tracker.example.com/?u=http%253A%252F%252F192.168.1.1%252F",
            "https://tracker.example.com/?u=http%3A%2F%2F192.168.1.1%2F&u=https%3A%2F%2Fexample.com%2F",
            "https://href.example.com/?http://192.168.1.1/",
        ] {
            XCTAssertEqual(refusal(text), .localNetwork, text)
        }
    }

    func testALinkThatMayCarryASecretIsNotLoaded() {
        for text in [
            "https://example.com/?token=abc", "https://example.com/?access_token=abc",
            "https://example.com/?api_key=abc",
            "https://example.com/?apiKey=abc", "https://example.com/?APIKey=abc", "https://example.com/?Key=abc",
            "https://example.com/file?X-Amz-Signature=abc&X-Amz-Credential=def", "https://example.com/?sig=abc",
            "https://example.com/callback?code=abc&state=xyz", "https://example.com/?client_secret=abc",
            "https://example.com/?password=abc", "https://example.com/?sessionID=abc", "https://example.com/?sid=abc",
            "https://example.com/?otp=123456", "https://example.com/?auth=abc", "https://example.com/?ticket=abc",
            "https://example.com/?jwt=abc", "https://example.com/?token2=abc", "https://example.com/?reset_token",
            "https://example.com/?resetToken=abc", "https://example.com/?userPassword=abc",
            // In the fragment, as a sign-in hands a token back, also after a route.
            "https://example.com/#access_token=abc&token_type=bearer", "https://example.com/#/reset?token=abc",
            // Sessions and keys by their usual names, also run together, and in the path as servers put them.
            "https://app.example.com/home.do;jsessionid=0A1B2C3D", "https://example.com/?PHPSESSID=abc",
            "https://example.com/?sesskey=abc", "https://example.com/?authtoken=abc",
            "https://example.com/?accesstoken=abc", "https://example.com/?secretkey=abc",
            "https://example.com/?hmac=abc",
            "https://example.com/?csrf=abc",
            // A code to sign in or prove who someone is.
            "https://example.com/?verification_code=123456", "https://example.com/?oob_code=abc",
            "https://example.com/?resetCode=abc",
            "https://example.com/?Authorization=abc", "https://example.com/?bearer=abc",
            "https://example.com/?totp=123456", "https://example.com/?mfa=1",
            "https://shop.example.com/;jsessionid=0A1B2C3D",
            // Any code that isn't plainly a country's, a postal one and the like.
            "https://example.com/?mfa_code=1", "https://example.com/?2fa_code=1", "https://example.com/?sms_code=1",
            "https://example.com/?email_code=1", "https://example.com/?one_time_code=1",
            "https://example.com/?user_code=1",
            "https://example.com/?authcode=1", "https://example.com/?accesscode=1", "https://example.com/?verifycode=1",
            "https://example.com/?resetcode=1", "https://example.com/?otpcode=1", "https://example.com/?smscode=1",
            "https://example.com/?securitycode=1", "https://example.com/?logincode=1",
            // A secret in a link another carries, escaped.
            "https://tracker.example.com/?u=https%3A%2F%2Fapp.example.com%2Fcb%3Ftoken%3Dabc",
            ("https://nam12.safelinks.example.com/?url=https%3A%2F%2Fapp.example.com%2Fsso%3Fjwt%3D"
                + "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlMTIz&reserved=0"),
            // A token escaped twice, after an escape that isn't one.
            "https://example.com/?x=%25ZZ%253Fnext%253DeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlMTIz",
            // A JSON Web Token anywhere in the address.
            "https://example.com/verify/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJlMTIz",
        ] {
            XCTAssertEqual(refusal(text), .mayHoldSecret, text)
        }
    }

    func testALinkCarriedThreeDeepIsStillRead() throws {
        func escaped(_ text: String) throws -> String {
            try XCTUnwrap(text.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        }
        let inner = "https://c.example.com/cb?token=abc"
        let two = "https://b.example.com/?u=" + (try escaped(inner))
        let one = "https://a.example.com/?u=" + (try escaped(two))
        XCTAssertEqual(refusal("https://tracker.example.com/?u=" + (try escaped(one))), .mayHoldSecret)
    }

    func testAVeryLongLinkIsNotLoadedAndALongOneIsReadAtOnce() {
        let veryLong = "https://example.com/" + String(repeating: "eyJ", count: 30_000)
        XCTAssertEqual(refusal(veryLong), .notWebLink)
        // Read in one pass however it repeats what a token begins with.
        let long = "https://example.com/" + String(repeating: "eyJabc", count: 1_300)
        XCTAssertNil(refusal(long))
        XCTAssertEqual(refusal(long + ".eyJsdWIiOiIxMjM0In0.c2lnbmF0dXJl"), .mayHoldSecret)
    }

    func testTheAddressLoadedIsTheLinkAsWritten() throws {
        XCTAssertEqual(try loaded("  https://example.com/a?b=c#d\n").absoluteString, "https://example.com/a?b=c#d")
        // A name in other scripts is loaded by its ASCII form.
        XCTAssertEqual(try loaded("https://例子.测试/").host(), "xn--fsqu00a.xn--0zwm56d")
    }

    func testAPreviewIsKeptUnderTheAddressWithoutWhatOnlyThePageReads() throws {
        XCTAssertEqual(try key("HTTPS://Example.COM:443/Path?b=2#frag"), "https://example.com/Path?b=2")
        XCTAssertEqual(try key("http://example.com:80"), "http://example.com/")
        XCTAssertEqual(try key("https://example.com:8443/a"), "https://example.com:8443/a")
        XCTAssertEqual(try key("http://example.com./"), "http://example.com/")
        XCTAssertEqual(try key("https://例子.测试/"), "https://xn--fsqu00a.xn--0zwm56d/")
        XCTAssertNotEqual(try key("https://example.com/a?b=1"), try key("https://example.com/a?b=2"))
        XCTAssertNotEqual(try key("https://example.com/A"), try key("https://example.com/a"))
    }

    // MARK: Helpers

    private func refusal(_ text: String) -> LinkAddress.Refusal? {
        if case .failure(let refusal) = LinkAddress.loadable(text) { return refusal }
        return nil
    }

    private func loaded(_ text: String) throws -> URL {
        try LinkAddress.loadable(text).get()
    }

    private func key(_ text: String) throws -> String {
        LinkAddress.key(for: try loaded(text))
    }
}

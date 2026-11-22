@testable import CalendarModule
import Foundation
import Testing

@Suite struct LinkTests {
    private func link(url: String? = nil, location: String? = nil, notes: String? = nil) -> MeetingLink? {
        MeetingLinkExtractor.extract(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
    }

    static let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NzA4YjRh%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22b1c2%22%7d"

    @Test func teamsInOutlookPlainTextNotes() {
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting<\(Self.teams)>
        Meeting ID: 123 456 789
        Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=1>
        """
        let l = link(location: "Microsoft Teams Meeting", notes: notes)
        #expect(l?.provider == .teams)
        #expect(l?.url.absoluteString == Self.teams)
    }

    // MARK: App links

    @Test func teamsJoinLinkOpensInTheApp() {
        let app = link(notes: Self.teams)?.appURL
        #expect(app?.absoluteString == "msteams:" + Self.teams.dropFirst("https://teams.microsoft.com".count))
        #expect(app?.scheme == "msteams")
        #expect(app?.host() == nil)
        #expect(link(notes: "https://teams.cloud.microsoft/l/meetup-join/19%3ameeting_x%40thread.v2/0")?.appURL?.absoluteString
            == "msteams:/l/meetup-join/19%3ameeting_x%40thread.v2/0")
    }

    @Test func zoomMeetingOpensInTheApp() {
        #expect(link(notes: "https://acme.zoom.us/j/842000000?pwd=Ab.c-1_2&from=addon")?.appURL?.absoluteString
            == "zoommtg://acme.zoom.us/join?confno=842000000&pwd=Ab.c-1_2")
        #expect(link(notes: "https://zoom.us/j/84200000012")?.appURL?.absoluteString == "zoommtg://zoom.us/join?confno=84200000012")
    }

    @Test func linksWithoutAKnownAppFormStayInTheBrowser() {
        for text in [
            "https://teams.microsoft.com/meet/2468?p=x1y2", "https://teams.live.com/meet/9876543210?p=abc",
            "https://acme.zoom.us/w/842000000", "https://acme.zoom.us/wc/join/842000000",
            "https://meet.google.com/abc-defg-hij", "https://acme.webex.com/meet/someone",
        ] {
            let l = link(notes: text)
            #expect(l != nil, "\(text)")
            #expect(l?.appURL == nil, "\(text)")
        }
    }

    @Test func teamsLiveAndShortMeetLinks() {
        #expect(link(notes: "Join: https://teams.live.com/meet/9876543210?p=abc")?.provider == .teams)
        #expect(link(notes: "https://teams.microsoft.com/meet/2468?p=x1y2")?.provider == .teams)
        #expect(link(notes: "https://teams.microsoft.com/meetingOptions/?id=1") == nil)
    }

    @Test func googleMeet() {
        let l = link(notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij\nOr dial: +1 555")
        #expect(l?.provider == .meet)
        #expect(l?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(link(notes: "https://meet.google.com/") == nil)
    }

    @Test func zoomWebAndNative() {
        let web = link(location: "https://us02web.zoom.us/j/81234567890?pwd=QWERTY.1")
        #expect(web?.provider == .zoom)
        #expect(web?.url.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=QWERTY.1")
        // Custom schemes and personal (non-numeric) rooms are not opened.
        #expect(link(notes: "zoommtg://zoom.us/join?confno=81234567890&pwd=abc") == nil)
        #expect(link(notes: "https://zoom.us/my/someroom") == nil)
        #expect(link(notes: "https://acme.zoom.us/w/91234567890")?.provider == .zoom)
        #expect(link(notes: "Download Zoom: https://zoom.us/download") == nil)
    }

    @Test func webex() {
        #expect(link(notes: "https://acme.webex.com/acme/j.php?MTID=m1234abcd")?.provider == .webex)
        #expect(link(notes: "https://acme.webex.com/meet/jane.doe")?.provider == .webex)
        #expect(link(notes: "Learn more at https://www.webex.com/features") == nil)
    }

    @Test func outlookSafeLinksAreUnwrapped() {
        let wrapped = "https://eur02.safelinks.protection.outlook.com/?url="
            + Self.teams.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            + "&data=05%7C02%7C&sdata=abc%3D&reserved=0"
        let l = link(notes: "Join <\(wrapped)>")
        #expect(l?.provider == .teams)
        #expect(l?.url.absoluteString == Self.teams)

        let zoomWrapped = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F812345678%3Fpwd%3Dz&data=1"
        #expect(link(url: zoomWrapped)?.url.absoluteString == "https://acme.zoom.us/j/812345678?pwd=z")
    }

    @Test func teamsAtpSafeLinksPageIsUnwrapped() {
        let atp = "https://statics.teams.cdn.office.net/evergreen-assets/safelinks/1/atp-safelinks.html?url=https%3A%2F%2Fmeet.google.com%2Fxyz-abcd-efg"
        #expect(link(notes: atp)?.url.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }

    @Test func htmlNotesWithEntities() {
        let html = """
        <html><body><div><p>Hi all,</p><a href="https://acme.zoom.us/j/555123456?pwd=a1&amp;uname=x" target="_blank">Join Zoom Meeting</a>&nbsp;<br></div></body></html>
        """
        let l = link(notes: html)
        #expect(l?.provider == .zoom)
        // Only the passcode survives the rebuild.
        #expect(l?.url.absoluteString == "https://acme.zoom.us/j/555123456?pwd=a1")
    }

    @Test func trailingPunctuationIsTrimmed() {
        #expect(link(notes: "Link: https://meet.google.com/abc-defg-hij.")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(link(notes: "(https://meet.google.com/abc-defg-hij)")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func orderIsURLThenLocationThenNotes() {
        let l = link(
            url: "https://meet.google.com/aaa-bbbb-ccc", location: "https://acme.zoom.us/j/812345678", notes: Self.teams
        )
        #expect(l?.provider == .meet)
        #expect(link(url: "https://outlook.office.com/calendar/item/1", location: "https://acme.zoom.us/j/812345678", notes: Self.teams)?.provider == .zoom)
        #expect(link(location: "Room 4.12", notes: Self.teams)?.provider == .teams)
    }

    @Test func nothingRecognised() {
        #expect(link() == nil)
        #expect(link(location: "Conference room B", notes: "Agenda: https://example.com/doc and mailto:x@y.z") == nil)
        #expect(MeetingLinkExtractor.urls(in: "no links here :// at all").isEmpty)
    }

    @Test func providerPresentation() {
        #expect(MeetingProvider.allCases.map(\.label) == ["Teams", "Google Meet", "Zoom", "Webex"])
        #expect(Set(MeetingProvider.allCases.map(\.symbol)).count == 4)
    }

    // MARK: hostile input

    @Test func customSchemesAreNeverOpened() {
        for text in [
            "zoommtg://zoom.us/join?action=join&confno=81234567890&zc=0&browser=evil",
            "zoomus://zoom.us/join?confno=81234567890&stype=100&token=x",
            "msteams:/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
            "msteams://teams.microsoft.com/l/meetup-join/19%3a1",
            "webex://meet?url=https://evil.example",
            "javascript://teams.microsoft.com/%0aalert(1)",
            "file:///Applications/Calculator.app",
        ] {
            #expect(link(notes: text) == nil, "\(text)")
            #expect(link(url: text) == nil, "\(text)")
        }
    }

    @Test func lookAlikeHostsAreRejected() {
        for text in [
            "https://zoom.us.evil.example/j/81234567890",
            "https://evil-zoom.us/j/81234567890",
            "https://evilzoom.us/j/81234567890",
            "https://teams.microsoft.com.evil.example/l/meetup-join/19%3a1",
            "https://meet.google.com.evil.example/abc-defg-hij",
            "https://webex.com.evil.example/meet/x",
            "https://notteams.live.com/meet/1",
        ] {
            #expect(link(notes: text) == nil, "\(text)")
        }
    }

    @Test func userinfoAndPortTricksAreRejected() {
        #expect(link(notes: "https://zoom.us@evil.example/j/81234567890") == nil)
        #expect(link(notes: "https://evil.example@zoom.us/j/81234567890") == nil) // userinfo itself is refused
        #expect(link(notes: "https://user:pass@acme.zoom.us/j/81234567890") == nil)
        #expect(link(notes: "https://acme.zoom.us:8443/j/81234567890") == nil)
        #expect(link(notes: "https://acme.zoom.us:443/j/81234567890")?.url.absoluteString == "https://acme.zoom.us/j/81234567890")
    }

    @Test func zoomNeedsANumericMeetingID() {
        #expect(link(notes: "https://acme.zoom.us/j/81234abc90") == nil)
        #expect(link(notes: "https://acme.zoom.us/j/123") == nil)
        #expect(link(notes: "https://acme.zoom.us/j/81234567890/../../evil") == nil)
        #expect(link(notes: "https://acme.zoom.us/j/%38%31%32%33%34%35%36%37%38") == nil) // percent-encoded digits
        #expect(link(notes: "https://acme.zoom.us/j/81234567890?pwd=ok&zc=0&browser=evil")?.url.absoluteString
            == "https://acme.zoom.us/j/81234567890?pwd=ok")
        #expect(link(notes: "https://acme.zoom.us/j/81234567890?pwd=%22%3E%3Cx")?.url.absoluteString
            == "https://acme.zoom.us/j/81234567890")
    }

    @Test func mixedCaseAndHttpAreNormalised() {
        #expect(link(notes: "HTTPS://ACME.ZOOM.US/J/81234567890")?.url.absoluteString == "https://acme.zoom.us/J/81234567890")
        #expect(link(notes: "http://meet.google.com/abc-defg-hij")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(link(notes: "https://Teams.Microsoft.com/l/meetup-join/19%3a1")?.url.host() == "teams.microsoft.com")
        #expect(link(notes: "https://meet.google.com/ABC-DEFG-HIJ") == nil) // codes are lowercase
    }

    @Test func percentEncodedHostsAreRejected() {
        #expect(link(notes: "https://zo%6Fm.us/j/81234567890") == nil)
        #expect(link(notes: "https://teams.microsoft.com%2Eevil.example/l/meetup-join/1") == nil)
    }

    @Test func safeLinksCannotSmuggleACustomScheme() {
        let wrapped = "https://eur02.safelinks.protection.outlook.com/?url=zoommtg%3A%2F%2Fzoom.us%2Fjoin%3Fconfno%3D81234567890"
        #expect(link(notes: wrapped) == nil)
    }

    @Test func dotSegmentsAreRejectedForEveryProvider() {
        let users = "?users=8:orgid:00000000-0000-0000-0000-000000000000"
        for text in [
            "https://teams.microsoft.com/l/meetup-join/../../l/call/0/0\(users)",
            "https://teams.microsoft.com/l/meetup-join/%2e%2e/%2e%2e/l/call/0/0\(users)",
            "https://teams.microsoft.com/l/meetup-join/%2E%2E/%2E%2E/l/call/0/0\(users)",
            "https://teams.microsoft.com/l/meetup-join/.%2E/%2e./l/call/0/0\(users)",
            "https://teams.microsoft.com/l/meetup-join/%252e%252e/%252E%252E/l/call/0/0\(users)",  // encoded twice
            "https://teams.microsoft.com/l/meetup-join/%2e%2e%2f%2e%2e%2fl/call/0/0\(users)",  // encoded slashes
            "https://teams.microsoft.com/l/meetup-join/..%5c..%5cl/call/0/0\(users)",  // encoded backslashes
            "https://teams.microsoft.com/l/meetup-join/./19%3ameeting_x%40thread.v2/0",
            "https://teams.cloud.microsoft/l/meetup-join/19%3ameeting_x%40thread.v2/0/../../../l/call/0/0",
            "https://teams.microsoft.com/meet/../l/call/0/0",
            "https://teams.live.com/meet/%2E%2E/l/chat/0/0",
            "https://acme.zoom.us/j/81234567890/../w",
            "https://acme.zoom.us/wc/join/%2e%2E/81234567890",
            "https://meet.google.com/./abc-defg-hij",
            "https://acme.webex.com/meet/../../admin",
            "https://acme.webex.com/meet/%2e%2e/admin",
            "https://acme.webex.com/meet/./x",
            "https://acme.webex.com/meet/%zz",  // broken encoding
        ] {
            #expect(link(notes: text) == nil, "\(text)")
            #expect(link(url: text) == nil, "\(text)")
        }
        // Names that merely contain dots are fine.
        #expect(link(notes: "https://acme.webex.com/meet/first.last")?.provider == .webex)
        #expect(link(notes: "https://acme.webex.com/meet/...")?.provider == .webex)
    }

    @Test func dotSegmentsInsideSafeLinksAreRejected() {
        let hostile = "https://teams.microsoft.com/l/meetup-join/../../l/call/0/0?users=x"
        let wrapped = "https://eur02.safelinks.protection.outlook.com/?url="
            + hostile.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(link(notes: wrapped) == nil)
    }

    @Test func theTeamsAppLinkNeedsTheMeetupJoinShape() {
        // Still a Teams link for the browser, but not in a form the app link is built from.
        for text in [
            "https://teams.microsoft.com/l/meetup-join/19%3a1",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0/extra",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0/",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/zero",
            "https://teams.microsoft.com/l/meetup-join/meeting_x%40thread.v2/0",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting%2fx%40thread.v2/0",  // an encoded slash in the thread
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting%3cx%3e/0",
            "https://teams.microsoft.com/l/meetup-join//19%3ameeting_x%40thread.v2/0",
        ] {
            let l = link(notes: text)
            #expect(l?.provider == .teams, "\(text)")
            #expect(l?.appURL == nil, "\(text)")
        }
        #expect(link(notes: "https://teams.microsoft.com/L/Meetup-Join/19%3Ameeting_x%40thread.tacv2/12?context=%7b%7d")?.appURL?.absoluteString
            == "msteams:/L/Meetup-Join/19%3Ameeting_x%40thread.tacv2/12?context=%7b%7d")
    }

    @Test func theAppLinkIsCheckedEvenForALinkBuiltByHand() {
        // `appURL` does not rely on `classify` having run first.
        let hostile = MeetingLink(provider: .teams, url: URL(string: "https://teams.microsoft.com/l/meetup-join/../../l/call/0/0?users=x")!)
        #expect(hostile.appURL == nil)
        let encoded = MeetingLink(provider: .teams, url: URL(string: "https://teams.microsoft.com/l/meetup-join/%2e%2e/%2E%2e/l/call/0/0")!)
        #expect(encoded.appURL == nil)
    }

    @Test func dotSegmentDetection() {
        #expect(MeetingLinkExtractor.hasDotSegments("/a/../b"))
        #expect(MeetingLinkExtractor.hasDotSegments("/a/./b"))
        #expect(MeetingLinkExtractor.hasDotSegments("/a/%2e%2E"))
        #expect(MeetingLinkExtractor.hasDotSegments("/a/%25%32%65%25%32%65/b"))  // "%2e%2e" encoded again
        #expect(MeetingLinkExtractor.hasDotSegments("/a/%"))
        #expect(!MeetingLinkExtractor.hasDotSegments("/a/b.c/...d/e..f"))
        #expect(!MeetingLinkExtractor.hasDotSegments(""))
        #expect(!MeetingLinkExtractor.hasDotSegments("/l/meetup-join/19%3ameeting_x%40thread.v2/0"))
    }
}

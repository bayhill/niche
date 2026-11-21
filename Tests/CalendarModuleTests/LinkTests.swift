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
        #expect(link(notes: "zoommtg://zoom.us/join?confno=81234567890&pwd=abc")?.provider == .zoom)
        #expect(link(notes: "https://zoom.us/my/someroom")?.provider == .zoom)
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

        let zoomWrapped = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Facme.zoom.us%2Fj%2F123%3Fpwd%3Dz&data=1"
        #expect(link(url: zoomWrapped)?.url.absoluteString == "https://acme.zoom.us/j/123?pwd=z")
    }

    @Test func teamsAtpSafeLinksPageIsUnwrapped() {
        let atp = "https://statics.teams.cdn.office.net/evergreen-assets/safelinks/1/atp-safelinks.html?url=https%3A%2F%2Fmeet.google.com%2Fxyz-abcd-efg"
        #expect(link(notes: atp)?.url.absoluteString == "https://meet.google.com/xyz-abcd-efg")
    }

    @Test func htmlNotesWithEntities() {
        let html = """
        <html><body><div><p>Hi all,</p><a href="https://acme.zoom.us/j/555?pwd=a1&amp;uname=x" target="_blank">Join Zoom Meeting</a>&nbsp;<br></div></body></html>
        """
        let l = link(notes: html)
        #expect(l?.provider == .zoom)
        #expect(l?.url.absoluteString == "https://acme.zoom.us/j/555?pwd=a1&uname=x")
    }

    @Test func trailingPunctuationIsTrimmed() {
        #expect(link(notes: "Link: https://meet.google.com/abc-defg-hij.")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(link(notes: "(https://meet.google.com/abc-defg-hij)")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func orderIsURLThenLocationThenNotes() {
        let l = link(
            url: "https://meet.google.com/aaa-bbbb-ccc", location: "https://acme.zoom.us/j/1", notes: Self.teams
        )
        #expect(l?.provider == .meet)
        #expect(link(url: "https://outlook.office.com/calendar/item/1", location: "https://acme.zoom.us/j/1", notes: Self.teams)?.provider == .zoom)
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
}

# Security

OpenLyrics reads the now-playing track from Music and Spotify, sends the track's title, artist,
album and length to lyrics services, and — only with React to the Music on — listens to the Mac's
sound output (never the microphone). If you find a way it could expose more than that, or any
other security problem, please report it privately through GitHub's
[security advisories](../../security/advisories/new) instead of opening a public issue.

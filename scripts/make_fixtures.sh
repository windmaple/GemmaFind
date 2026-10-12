#!/usr/bin/env bash
# Generates a small mixed-media corpus for end-to-end testing of GemmaFind.
#   scripts/make_fixtures.sh [output-dir]   (default: Tests/Fixtures/corpus)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="${1:-Tests/Fixtures/corpus}"
rm -rf "$OUT"; mkdir -p "$OUT/notes" "$OUT/code" "$OUT/docs" "$OUT/photos" "$OUT/media"

cat > "$OUT/notes/kyoto-trip.md" <<'EOF'
# Kyoto, April

Day one we took the early Shinkansen from Tokyo and dropped our bags at a small ryokan near Gion.
In the afternoon we climbed through the thousands of vermilion torii gates at Fushimi Inari. The path
up the mountain is quieter after the first hour, and the view over the city at sunset was unforgettable.

Day two was temples: the golden pavilion at Kinkaku-ji in the morning and Ryoan-ji's rock garden after
lunch. We finished in the Arashiyama bamboo grove, which is magical early but packed by ten.

Food highlights: matcha soft-serve, yudofu (simmered tofu) near Nanzen-ji, and a tiny izakaya where the
owner grilled skewers over binchotan charcoal.
EOF

cat > "$OUT/notes/sourdough.txt" <<'EOF'
Sourdough routine
Feed the starter the night before so it is bubbly and doubled by morning.
Mix 500 g flour with 350 g water and let it autolyse for an hour, then add 100 g starter and 10 g salt.
Do four sets of stretch-and-folds, 30 minutes apart, then let the dough bulk ferment until it has grown about 50%.
Shape, put it in a floured banneton and retard it in the fridge overnight.
Bake in a preheated Dutch oven at 250 C: 20 minutes lid on, 25 minutes lid off, until deep brown.
EOF

cat > "$OUT/notes/meeting-2026-09-30.txt" <<'EOF'
Weekly sync — infrastructure
Attendees: Priya, Marco, Lena
- The database migration to the new cluster finished on Tuesday; p99 latency dropped from 180 ms to 95 ms.
- Server costs are down 18% month over month after we turned off the old replicas.
- Action item: Marco to write the postmortem for the Saturday outage caused by an expired TLS certificate.
- Action item: Lena to set up certificate expiry alerts in the monitoring dashboard.
EOF

cat > "$OUT/code/retry.py" <<'EOF'
import random
import time


def retry_with_backoff(fn, attempts=5, base_delay=0.5, max_delay=8.0):
    """Call fn, retrying on exception with exponential backoff and full jitter."""
    for attempt in range(attempts):
        try:
            return fn()
        except Exception:
            if attempt == attempts - 1:
                raise
            delay = min(max_delay, base_delay * (2 ** attempt))
            time.sleep(random.uniform(0, delay))
EOF

cat > "$OUT/code/LRUCache.swift" <<'EOF'
/// A fixed-capacity least-recently-used cache backed by a dictionary and a doubly linked list.
final class LRUCache<Key: Hashable, Value> {
    private final class Node { let key: Key; var value: Value; var prev: Node?; var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value } }
    private var map: [Key: Node] = [:]
    private var head: Node?, tail: Node?
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }

    func get(_ key: Key) -> Value? {
        guard let node = map[key] else { return nil }
        moveToFront(node); return node.value
    }

    func set(_ key: Key, _ value: Value) {
        if let node = map[key] { node.value = value; moveToFront(node); return }
        let node = Node(key: key, value: value); map[key] = node; insertFront(node)
        if map.count > capacity, let lru = tail { remove(lru); map[lru.key] = nil }   // evict oldest
    }
    private func moveToFront(_ n: Node) { remove(n); insertFront(n) }
    private func insertFront(_ n: Node) { n.next = head; head?.prev = n; head = n; if tail == nil { tail = n } }
    private func remove(_ n: Node) { n.prev?.next = n.next; n.next?.prev = n.prev
        if head === n { head = n.next }; if tail === n { tail = n.prev }; n.prev = nil; n.next = nil }
}
EOF

# Rich documents via textutil, PDF via cupsfilter.
cat > /tmp/gf_lease.txt <<'EOF'
Residential Lease Agreement

This agreement is made between the landlord, Harbor Properties LLC, and the tenant for the apartment at 42 Seaview Road.
The monthly rent is 2,400 dollars, due on the first day of each month. A late fee of 75 dollars applies after the fifth day.
The security deposit equals one month of rent and will be returned within 30 days after move-out, minus any damages.
Pets are allowed with prior written consent and an additional pet deposit of 500 dollars.
The tenant may terminate early with 60 days notice and payment of one month's rent as a break fee.
EOF
textutil -convert docx /tmp/gf_lease.txt -output "$OUT/docs/lease-agreement.docx"

cat > /tmp/gf_warranty.txt <<'EOF'
Espresso Machine — Warranty and Care

Your machine is covered for two years against manufacturing defects. Descale every three months using citric acid
or the supplied descaling solution; hard water areas may need monthly descaling. Never immerse the base in water.
If the pump makes a loud buzzing noise but no water flows, the boiler may be empty: refill the tank and run the steam wand.
EOF
textutil -convert rtf /tmp/gf_warranty.txt -output "$OUT/docs/espresso-warranty.rtf"

cat > "$OUT/docs/hiking-checklist.html" <<'EOF'
<html><head><title>Hiking checklist</title><style>body{font-family:sans-serif}</style></head>
<body><h1>Day hike checklist</h1><ul><li>Two liters of water and electrolyte tablets</li>
<li>Rain shell and a warm fleece layer</li><li>Headlamp with spare batteries</li>
<li>Offline map and a paper map with compass</li><li>First-aid kit, blister plasters and sunscreen</li></ul>
<p>Tell someone your route and expected return time before you leave.</p></body></html>
EOF

cat > /tmp/gf_paper.txt <<'EOF'
Solar Panel Efficiency in Cold Climates

Abstract. Photovoltaic modules are often assumed to perform poorly in winter, yet lower cell temperatures increase
open-circuit voltage and conversion efficiency. We measured twelve rooftop installations in northern Norway over two years.

Results. Snow cover was the dominant source of loss, reducing annual yield by 9 percent on low-tilt roofs.
Panels mounted at 60 degrees shed snow quickly and produced 14 percent more energy per installed kilowatt than
identical panels in southern Spain during clear spring days, thanks to cold temperatures and reflected light from snow (albedo).

Conclusion. Steep mounting angles and bifacial modules are recommended for high-latitude installations.
EOF
cupsfilter /tmp/gf_paper.txt > "$OUT/docs/solar-cold-climates.pdf" 2>/dev/null

# Photos from Wikimedia Commons (resized server-side).
fetch() { curl -sfL -A "GemmaFind-fixtures/1.0" -o "$OUT/photos/$2" "https://commons.wikimedia.org/wiki/Special:FilePath/$1?width=640" || echo "warn: could not fetch $1"; }
fetch "Cat_November_2010-1a.jpg" "IMG_0412.jpg"                     # cat
fetch "YellowLabradorLooking_new.jpg" "IMG_0413.jpg"                # dog
fetch "Eq_it-na_pizza-margherita_sep2005_sml.jpg" "IMG_0420.jpg"    # pizza
fetch "Tour_Eiffel_Wikimedia_Commons.jpg" "IMG_0431.jpg"            # Eiffel tower
fetch "Left_side_of_Flying_Pigeon.jpg" "IMG_0444.jpg"               # bicycle

# Spoken audio via `say`.
say -o "$OUT/media/voice-memo-1.m4a" --file-format=m4af \
  "Reminder for tomorrow. Pick up the dry cleaning, buy birthday candles and a chocolate cake for Emma's party, and call the dentist to reschedule."
say -o "$OUT/media/voice-memo-2.m4a" --file-format=m4af \
  "Quarterly earnings update. Revenue grew twelve percent year over year, operating margin improved, and we are raising guidance for the full year."

# Video: 12 s of the dog photo then 12 s of the pizza photo, narrated.
if [ -f "$OUT/photos/IMG_0413.jpg" ] && [ -f "$OUT/photos/IMG_0420.jpg" ]; then
  say -o /tmp/gf_narration.aiff "Here is our dog playing in the garden. And later we made pizza margherita for dinner."
  ffmpeg -loglevel error -y \
    -loop 1 -t 12 -i "$OUT/photos/IMG_0413.jpg" -loop 1 -t 12 -i "$OUT/photos/IMG_0420.jpg" -i /tmp/gf_narration.aiff \
    -filter_complex "[0:v]scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1[v0];[1:v]scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1[v1];[v0][v1]concat=n=2:v=1:a=0[v]" \
    -map "[v]" -map 2:a -af apad -c:v libx264 -pix_fmt yuv420p -r 10 -c:a aac -t 24 "$OUT/media/weekend.mp4"
fi

echo "Fixtures written to $OUT"
find "$OUT" -type f | sort

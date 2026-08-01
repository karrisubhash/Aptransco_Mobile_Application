"""Shared SAP-line <-> ArcGIS-Line name matching logic — used by both the
map_sap_lines management command (writes high-confidence matches directly)
and the SAP<->ArcGIS mapping admin page (shows ranked suggestions for
manual review). One implementation so the two never disagree.
"""
import re

NOISE_TOKENS = {
    'LINE', 'KV', 'DC', 'SC', 'TM', 'CIRCUIT', 'CKT', 'TIE', 'TAP', 'FEEDER', 'AND', 'THE',
}
VOLTAGE_RE = re.compile(r'(\d+)\s*KV')
CIRCUIT_RE = re.compile(r'(?:CKT|CIRCUIT)[-\s]*(\d+)|[-\s](\d+)\s*$')
TOKEN_RE = re.compile(r'[A-Z0-9]+')

HIGH_CONFIDENCE_JACCARD = 0.75


def _voltage_of(text):
    match = VOLTAGE_RE.search(text.upper())
    return f'{match.group(1)}kV' if match else ''


def _circuit_of(text):
    match = CIRCUIT_RE.search(text.upper())
    if not match:
        return None
    return match.group(1) or match.group(2)


def token_set(text):
    upper = (text or '').upper()
    voltage_match = VOLTAGE_RE.search(upper)
    if voltage_match:
        upper = upper.replace(voltage_match.group(0), ' ')
    tokens = {t for t in TOKEN_RE.findall(upper) if len(t) >= 3 and t not in NOISE_TOKENS}
    return tokens


def match_score(line_name, line_voltage, sap_description, sap_voltage):
    """Returns (score 0..1, reason) for a candidate (Line, SapLine) pair."""
    if line_voltage and sap_voltage and line_voltage != sap_voltage:
        return 0.0, 'voltage mismatch'

    a, b = token_set(line_name), token_set(sap_description)
    if not a or not b:
        return 0.0, 'no comparable tokens'

    jaccard = len(a & b) / len(a | b)

    circuit_a, circuit_b = _circuit_of(line_name), _circuit_of(sap_description)
    if circuit_a and circuit_b and circuit_a != circuit_b:
        jaccard *= 0.3  # heavily penalize — almost certainly the wrong circuit of a duplicated route

    return jaccard, f'{len(a & b)}/{len(a | b)} tokens shared'


def find_best_matches(line, sap_line_candidates, top_n=3):
    """sap_line_candidates: iterable of SapLine. Returns top_n (SapLine, score, reason) tuples, best first."""
    scored = []
    for sap_line in sap_line_candidates:
        score, reason = match_score(line.name, line.voltage, sap_line.description, sap_line.voltage)
        if score > 0:
            scored.append((sap_line, score, reason))
    scored.sort(key=lambda item: item[1], reverse=True)
    return scored[:top_n]


def is_high_confidence(score):
    return score >= HIGH_CONFIDENCE_JACCARD

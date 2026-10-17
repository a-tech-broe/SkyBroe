import { useEffect, useRef, useState, type ReactNode } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  ScrollView,
  ActivityIndicator,
  StyleSheet,
  Platform,
  KeyboardAvoidingView,
  NativeSyntheticEvent,
  NativeScrollEvent,
  useWindowDimensions,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { api } from '../src/api/client';

const MONO = Platform.OS === 'ios' ? 'Courier New' : 'monospace';
const TABS = [
  { key: 'weather',  label: 'Weather',  icon: 'partly-sunny' as const },
  { key: 'notams',   label: 'NOTAMs',   icon: 'warning'      as const },
  { key: 'airports', label: 'Airports', icon: 'airplane'     as const },
];

// ─── Responsive layout hook ───────────────────────────────────────────────────
// Single source of truth for every size value. Re-runs on orientation change.

function useLayout() {
  const { width, height } = useWindowDimensions();
  const tablet    = width >= 600;
  const landscape = width > height;

  const pad        = tablet ? 24 : 16;
  const inputPadV  = tablet ? 17 : 12;
  const cardRadius = tablet ? 20 : 16;
  const inputRadius = tablet ? 14 : 10;

  const f = {
    xs:   tablet ? 13 : 11,   // labels, raw text
    sm:   tablet ? 15 : 13,   // body, NOTAM text
    base: tablet ? 17 : 14,   // airport name, location
    md:   tablet ? 18 : 15,   // input, button
    logo: tablet ? 22 : 18,
    icao: tablet ? 36 : 28,
  };

  // Stat-grid columns: 2 phone-portrait, 3 phone-landscape / tablet-portrait, 4 tablet-landscape
  const statCols = tablet ? (landscape ? 4 : 3) : (landscape ? 3 : 2);

  return {
    width, height, tablet, landscape,
    pad, inputPadV, cardRadius, inputRadius,
    f,
    statCols,
    segW:       width / TABS.length,
    logoIconSz: tablet ? 24 : 20,
    tabIconSz:  tablet ? 18 : 15,
    // Content is centered with max-width on tablet
    contentStyle: {
      maxWidth:  tablet ? (720 as number | undefined) : undefined,
      alignSelf: (tablet ? 'center' : undefined) as 'center' | undefined,
      width:     '100%' as const,
      padding:   tablet ? 24 : 16,
      paddingBottom: (tablet ? 32 : 24) as number,
      gap:       (tablet ? 16 : 12) as number,
    } as const,
  };
}

type Layout = ReturnType<typeof useLayout>;

// ─── Types ────────────────────────────────────────────────────────────────────

interface CloudLayer { cover: string; base: number }
interface MetarData {
  icaoId: string; name: string; temp: number; dewp: number;
  wdir: number | string; wspd: number; wgst: number | null;
  visib: string; altim: number; wxString: string | null;
  clouds: CloudLayer[]; rawOb: string;
}
interface AirportData {
  icaoId: string; iataId: string; name: string; state: string; country: string;
  lat: number; lon: number; elev: number; rwyDir: string; rwyLen: number;
}

// ─── Shared components ────────────────────────────────────────────────────────

function StatBox({ label, value, lay }: { label: string; value: string; lay: Layout }) {
  const minW = `${Math.floor(100 / lay.statCols) - 1}%` as `${number}%`;
  return (
    <View style={[s.statBox, { minWidth: minW, borderRadius: lay.inputRadius, padding: lay.pad * 0.65 }]}>
      <Text style={[s.statLabel, { fontSize: lay.f.xs }]}>{label}</Text>
      <Text style={[s.statValue, { fontSize: lay.f.sm }]}>{value}</Text>
    </View>
  );
}

function SearchRow({
  value, placeholder, onChangeText, onSubmit, btnLabel, loading, lay,
}: {
  value: string;
  placeholder: string;
  onChangeText: (t: string) => void;
  onSubmit: () => void;
  btnLabel: string;
  loading: boolean;
  lay: Layout;
}) {
  return (
    <View style={s.searchRow}>
      <TextInput
        style={[s.input, {
          paddingVertical: lay.inputPadV,
          borderRadius: lay.inputRadius,
          fontSize: lay.f.md,
        }]}
        placeholder={placeholder}
        placeholderTextColor="#475569"
        value={value}
        onChangeText={onChangeText}
        maxLength={4}
        autoCapitalize="characters"
        onSubmitEditing={onSubmit}
      />
      <TouchableOpacity
        style={[s.btn, {
          borderRadius: lay.inputRadius,
          paddingHorizontal: lay.pad,
          minHeight: lay.inputPadV * 2 + Math.ceil(lay.f.md * 1.4),
        }]}
        onPress={onSubmit}
        disabled={loading}
        activeOpacity={0.8}
      >
        <Text style={[s.btnText, { fontSize: lay.f.md }]}>{btnLabel}</Text>
      </TouchableOpacity>
    </View>
  );
}

// Centers and constrains content on tablet; full-width on phone
function PanelContent({ lay, children }: { lay: Layout; children: ReactNode }) {
  return (
    <View style={lay.contentStyle}>
      {children}
    </View>
  );
}

// ─── Weather Panel ────────────────────────────────────────────────────────────

function WeatherPanel({ screenWidth }: { screenWidth: number }) {
  const lay = useLayout();
  const [icao, setIcao] = useState('');
  const [metar, setMetar] = useState<MetarData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function search() {
    const id = icao.trim().toUpperCase();
    if (!id) return;
    setLoading(true); setError(''); setMetar(null);
    try {
      const res = await api.weather.metar(id) as MetarData[];
      setMetar(res[0] ?? null);
      if (!res[0]) setError(`No METAR found for ${id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed');
    } finally { setLoading(false); }
  }

  const fr = metar ? (() => {
    const vis = parseFloat(metar.visib);
    const ceil = metar.clouds
      ?.filter(c => ['BKN', 'OVC', 'OVX'].includes(c.cover))
      ?.reduce((mn, c) => Math.min(mn, c.base), Infinity) ?? Infinity;
    if (ceil < 500 || vis < 1) return { label: 'LIFR', color: '#d946ef' };
    if (ceil < 1000 || vis < 3) return { label: 'IFR',  color: '#ef4444' };
    if (ceil < 3000 || vis < 5) return { label: 'MVFR', color: '#3b82f6' };
    return { label: 'VFR', color: '#22c55e' };
  })() : null;

  return (
    <ScrollView
      style={{ flex: 1, width: screenWidth }}
      keyboardShouldPersistTaps="handled"
      nestedScrollEnabled
      showsVerticalScrollIndicator={false}
    >
      <PanelContent lay={lay}>
        <SearchRow
          value={icao}
          placeholder="ICAO (e.g. KJFK)"
          onChangeText={t => setIcao(t.toUpperCase())}
          onSubmit={search}
          btnLabel="Brief"
          loading={loading}
          lay={lay}
        />
        {loading && (
          <ActivityIndicator
            color="#3b82f6"
            size={lay.tablet ? 'large' : 'small'}
            style={{ marginTop: 32 }}
          />
        )}
        {error ? <Text style={[s.errorText, { fontSize: lay.f.base }]}>{error}</Text> : null}

        {metar && fr && (
          <View style={[s.card, { borderRadius: lay.cardRadius, padding: lay.pad }]}>
            <View style={s.cardHeader}>
              <Text style={[s.icaoText, { fontSize: lay.f.icao }]}>{metar.icaoId}</Text>
              <Text style={[s.frBadge, { color: fr.color, fontSize: lay.f.base }]}>{fr.label}</Text>
            </View>
            <Text style={[s.airportName, { fontSize: lay.f.base }]}>{metar.name}</Text>

            <View style={s.grid}>
              <StatBox lay={lay} label="Wind"
                value={`${metar.wdir}° ${metar.wspd}KT${metar.wgst ? ` G${metar.wgst}` : ''}`} />
              <StatBox lay={lay} label="Visibility" value={`${metar.visib} SM`} />
              <StatBox lay={lay} label="Altimeter"  value={`${metar.altim?.toFixed(2)}"`} />
              <StatBox lay={lay} label="Temp / Dew" value={`${metar.temp}° / ${metar.dewp}°C`} />
            </View>

            {metar.wxString
              ? <Text style={[s.wx, { fontSize: lay.f.sm }]}>{metar.wxString}</Text>
              : null}

            <Text style={[s.rawLabel, { fontSize: lay.f.xs }]}>RAW METAR</Text>
            <Text style={[s.raw, { fontSize: lay.f.xs, lineHeight: lay.f.xs * 1.65 }]}>
              {metar.rawOb}
            </Text>
          </View>
        )}
      </PanelContent>
    </ScrollView>
  );
}

// ─── NOTAMs Panel ─────────────────────────────────────────────────────────────

function NotamsPanel({ screenWidth }: { screenWidth: number }) {
  const lay = useLayout();
  const [icao, setIcao] = useState('');
  const [items, setItems] = useState<unknown[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function search() {
    const id = icao.trim().toUpperCase();
    if (!id) return;
    setLoading(true); setError(''); setItems([]);
    try {
      const res = await api.notams(id) as { items?: unknown[] };
      setItems(res.items ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed');
    } finally { setLoading(false); }
  }

  return (
    <ScrollView
      style={{ flex: 1, width: screenWidth }}
      keyboardShouldPersistTaps="handled"
      nestedScrollEnabled
      showsVerticalScrollIndicator={false}
    >
      <PanelContent lay={lay}>
        <SearchRow
          value={icao}
          placeholder="ICAO"
          onChangeText={t => setIcao(t.toUpperCase())}
          onSubmit={search}
          btnLabel="Fetch"
          loading={loading}
          lay={lay}
        />
        {loading && (
          <ActivityIndicator
            color="#3b82f6"
            size={lay.tablet ? 'large' : 'small'}
            style={{ marginTop: 32 }}
          />
        )}
        {error ? <Text style={[s.errorText, { fontSize: lay.f.base }]}>{error}</Text> : null}

        {items.map((item, i) => {
          const n = (item as {
            properties: {
              coreNOTAMData: {
                notam: { number: string; text: string; effectiveStart: string; effectiveEnd: string };
              };
            };
          }).properties?.coreNOTAMData?.notam;
          if (!n) return null;
          return (
            <View key={i} style={[s.card, { borderRadius: lay.cardRadius, padding: lay.pad }]}>
              <Text style={[s.notamNum,   { fontSize: lay.f.sm }]}>{n.number}</Text>
              <Text style={[s.notamDates, { fontSize: lay.f.xs }]}>
                {n.effectiveStart} → {n.effectiveEnd}
              </Text>
              <Text style={[s.notamText,  { fontSize: lay.f.sm, lineHeight: lay.f.sm * 1.6 }]}>
                {n.text}
              </Text>
            </View>
          );
        })}
      </PanelContent>
    </ScrollView>
  );
}

// ─── Airports Panel ───────────────────────────────────────────────────────────

function AirportsPanel({ screenWidth }: { screenWidth: number }) {
  const lay = useLayout();
  const [icao, setIcao] = useState('');
  const [airport, setAirport] = useState<AirportData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  async function search() {
    const id = icao.trim().toUpperCase();
    if (!id) return;
    setLoading(true); setError(''); setAirport(null);
    try {
      const res = await api.airports(id);
      if (!res) throw new Error(`${id} not found`);
      setAirport(res as AirportData);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed');
    } finally { setLoading(false); }
  }

  return (
    <ScrollView
      style={{ flex: 1, width: screenWidth }}
      keyboardShouldPersistTaps="handled"
      nestedScrollEnabled
      showsVerticalScrollIndicator={false}
    >
      <PanelContent lay={lay}>
        <SearchRow
          value={icao}
          placeholder="ICAO"
          onChangeText={t => setIcao(t.toUpperCase())}
          onSubmit={search}
          btnLabel="Lookup"
          loading={loading}
          lay={lay}
        />
        {loading && (
          <ActivityIndicator
            color="#3b82f6"
            size={lay.tablet ? 'large' : 'small'}
            style={{ marginTop: 32 }}
          />
        )}
        {error ? <Text style={[s.errorText, { fontSize: lay.f.base }]}>{error}</Text> : null}

        {airport && (
          <View style={[s.card, { borderRadius: lay.cardRadius, padding: lay.pad }]}>
            <View style={s.cardHeader}>
              <Text style={[s.icaoText, { fontSize: lay.f.icao }]}>{airport.icaoId}</Text>
              {airport.iataId
                ? <Text style={[s.iata, { fontSize: lay.f.base }]}>{airport.iataId}</Text>
                : null}
            </View>
            <Text style={[s.airportName, { fontSize: lay.f.base + 2, fontWeight: '600' }]}>
              {airport.name}
            </Text>
            <Text style={[s.location, { fontSize: lay.f.base }]}>
              {[airport.state, airport.country].filter(Boolean).join(', ')}
            </Text>

            <View style={s.grid}>
              <StatBox lay={lay} label="Elevation"   value={`${airport.elev} ft`} />
              <StatBox lay={lay} label="Lat"         value={`${airport.lat?.toFixed(4)}°`} />
              <StatBox lay={lay} label="Lon"         value={`${airport.lon?.toFixed(4)}°`} />
              {airport.rwyLen
                ? <StatBox lay={lay} label="Longest Rwy" value={`${airport.rwyLen} ft`} />
                : null}
            </View>

            {airport.rwyDir ? (
              <View>
                <Text style={[s.sectionLabel, { fontSize: lay.f.xs }]}>Runways</Text>
                <Text style={[s.rwy, { fontSize: lay.f.sm }]}>{airport.rwyDir}</Text>
              </View>
            ) : null}
          </View>
        )}
      </PanelContent>
    </ScrollView>
  );
}

// ─── Root ─────────────────────────────────────────────────────────────────────

export default function HomeScreen() {
  const lay = useLayout();
  const { width, segW } = lay;

  const [activeIndex, setActiveIndex] = useState(0);
  const pagerRef   = useRef<ScrollView>(null);
  const activeRef  = useRef(0); // tracks latest index without triggering effects

  // Keep ref in sync
  activeRef.current = activeIndex;

  // Re-snap pager to the correct page after rotation / width change
  useEffect(() => {
    pagerRef.current?.scrollTo({ x: activeRef.current * width, animated: false });
  }, [width]);

  function selectTab(index: number) {
    setActiveIndex(index);
    pagerRef.current?.scrollTo({ x: index * width, animated: true });
  }

  function onPagerScrollEnd(e: NativeSyntheticEvent<NativeScrollEvent>) {
    const index = Math.round(e.nativeEvent.contentOffset.x / width);
    if (index !== activeRef.current) setActiveIndex(index);
  }

  return (
    <SafeAreaView style={s.root} edges={['top', 'left', 'right', 'bottom']}>
      <KeyboardAvoidingView
        style={s.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
      >

        {/* ── Logo ─────────────────────────────────────────────────────── */}
        <View style={[s.header, { paddingHorizontal: lay.pad, paddingVertical: lay.tablet ? 14 : 10 }]}>
          <View style={s.logoRow}>
            <Ionicons name="airplane" size={lay.logoIconSz} color="#3b82f6" />
            <Text style={[s.logoText, { fontSize: lay.f.logo }]}>
              SKY<Text style={s.logoAccent}>OPS</Text>
            </Text>
          </View>
        </View>

        {/* ── Tab strip ────────────────────────────────────────────────── */}
        {/* Content width is fixed to `width` so each tab button is exactly segW wide,
            which keeps the indicator bar perfectly aligned regardless of screen size. */}
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          bounces={false}
          overScrollMode="never"
          style={s.tabBar}
          contentContainerStyle={{ flexDirection: 'row', width }}
        >
          {TABS.map((tab, i) => {
            const active = activeIndex === i;
            return (
              <TouchableOpacity
                key={tab.key}
                style={[
                  s.tabBtn,
                  active && s.tabBtnActive,
                  {
                    width: segW,
                    paddingVertical: lay.tablet ? 12 : 8,
                  },
                ]}
                onPress={() => selectTab(i)}
                activeOpacity={0.7}
              >
                <Ionicons
                  name={tab.icon}
                  size={lay.tabIconSz}
                  color={active ? '#3b82f6' : '#64748b'}
                />
                <Text style={[s.tabLabel, active && s.tabLabelActive, { fontSize: lay.tabIconSz - 1 }]}>
                  {tab.label}
                </Text>
              </TouchableOpacity>
            );
          })}
        </ScrollView>

        {/* Sliding indicator — width and position are always 1/3 of screen */}
        <View style={s.indicatorTrack}>
          <View
            style={[
              s.indicatorBar,
              { width: segW, transform: [{ translateX: activeIndex * segW }] },
            ]}
          />
        </View>

        {/* ── Pager ────────────────────────────────────────────────────── */}
        <ScrollView
          ref={pagerRef}
          horizontal
          pagingEnabled
          showsHorizontalScrollIndicator={false}
          bounces={false}
          overScrollMode="never"
          scrollEventThrottle={16}
          decelerationRate="fast"
          onMomentumScrollEnd={onPagerScrollEnd}
          style={s.pager}
          directionalLockEnabled
        >
          <WeatherPanel  screenWidth={width} />
          <NotamsPanel   screenWidth={width} />
          <AirportsPanel screenWidth={width} />
        </ScrollView>

      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

// ─── Static styles (color, flex structure, font-family only) ─────────────────
// All size values (fontSize, padding, borderRadius) are applied inline via useLayout.

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#020617' },
  flex: { flex: 1 },

  header: {
    backgroundColor: '#0f172a',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#1e293b',
  },
  logoRow:   { flexDirection: 'row', alignItems: 'center', gap: 8 },
  logoText:  { color: '#f1f5f9', fontWeight: '800', letterSpacing: 3, fontFamily: MONO },
  logoAccent: { color: '#3b82f6' },

  tabBar: { backgroundColor: '#0f172a', flexGrow: 0, flexShrink: 0 },
  tabBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    borderRadius: 8,
  },
  tabBtnActive: { backgroundColor: 'rgba(59,130,246,0.12)' },
  tabLabel:       { color: '#64748b', fontWeight: '600' },
  tabLabelActive: { color: '#3b82f6' },

  indicatorTrack: { height: 2, backgroundColor: '#1e293b' },
  indicatorBar:   { height: 2, backgroundColor: '#3b82f6', borderRadius: 1 },

  pager: { flex: 1 },

  searchRow: { flexDirection: 'row', gap: 8 },
  input: {
    flex: 1,
    backgroundColor: '#1e293b',
    paddingHorizontal: 16,
    color: '#f1f5f9',
    fontFamily: MONO,
    letterSpacing: 2,
    borderWidth: 1,
    borderColor: '#334155',
  },
  btn: {
    backgroundColor: '#2563eb',
    justifyContent: 'center',
    alignItems: 'center',
  },
  btnText:   { color: '#fff', fontWeight: '700' },
  errorText: { color: '#f87171', textAlign: 'center', marginTop: 16 },

  card: {
    backgroundColor: '#0f172a',
    borderWidth: 1,
    borderColor: '#1e293b',
    gap: 12,
  },
  cardHeader:  { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  icaoText:    { color: '#f1f5f9', fontWeight: '800', fontFamily: MONO },
  frBadge:     { fontWeight: '700', fontFamily: MONO },
  iata:        { color: '#475569', fontFamily: MONO },
  airportName: { color: '#94a3b8' },
  location:    { color: '#64748b' },

  grid:      { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  statBox:   { backgroundColor: '#020617', flex: 1 },
  statLabel: { color: '#475569', textTransform: 'uppercase', letterSpacing: 1 },
  statValue: { color: '#e2e8f0', fontFamily: MONO, marginTop: 3 },

  wx:       { color: '#fbbf24', fontFamily: MONO },
  rawLabel: { color: '#475569', textTransform: 'uppercase', letterSpacing: 1 },
  raw:      { color: '#64748b', fontFamily: MONO, backgroundColor: '#020617', borderRadius: 8, padding: 8 },

  sectionLabel: { color: '#475569', textTransform: 'uppercase', letterSpacing: 1, marginBottom: 4 },
  rwy:          { color: '#94a3b8', fontFamily: MONO },

  notamNum:   { color: '#60a5fa', fontFamily: MONO, fontWeight: '700' },
  notamDates: { color: '#475569', fontFamily: MONO },
  notamText:  { color: '#cbd5e1', fontFamily: MONO },
});

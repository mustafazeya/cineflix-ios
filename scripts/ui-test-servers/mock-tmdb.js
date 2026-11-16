// Stand-in for the TMDB API, used by the UI tests. A small fixed catalogue with every kind of rating (G, PG, PG-13, R, unrated,
// a title with mixed ratings, TV-Y7, TV-14, TV-MA) so the kids filter can be checked. Discover honours with_genres (comma = and,
// pipe = or) and certification.lte like the real one. Images are not served (the app shows its placeholder).
//
//   node scripts/ui-test-servers/mock-tmdb.js [port]      (default 8151)
// Point the app at it with: -cf.tmdbBase http://127.0.0.1:8151/3 -cf.tmdbToken test
const http = require('http');

const PORT = Number(process.argv[2] || process.env.PORT || 8151);
const ORDER = ['G', 'PG', 'PG-13', 'R', 'NC-17'];

// [id, title, US certifications (one per release), genre ids, popularity, vote average]
const MOVIES = [
  [9001, 'Pip the Penguin', ['G'], [16, 10751], 90, 7.9],
  [9002, 'Robo Pals', ['PG'], [16, 12], 88, 7.5],
  [9003, 'Garden Gnomes', ['G'], [10751, 35], 70, 6.8],
  [9004, 'Dragon Academy', ['PG-13'], [14, 12], 85, 7.2],
  [9005, 'Night Hollow', ['R'], [27], 95, 6.5],
  [9006, 'Cold Case Files', ['R'], [80, 53], 80, 7.0],
  [9007, 'Mystery Reel', [], [16, 35], 60, 6.1],
  [9008, 'Double Feature', ['PG', 'R'], [16, 35], 65, 6.9],
  [9009, 'Sunny Days', ['NR'], [10751], 50, 6.0],
  [9010, 'Midnight Heist', ['PG-13'], [28, 80], 75, 6.7],
  [9011, 'Space Pups', ['PG'], [16, 10751], 82, 7.4],
  [9012, 'Wild Action', ['PG-13'], [28, 12], 78, 6.6]
];
// [id, title, US content rating, genre ids, popularity, vote average]
const SHOWS = [
  [8001, 'Kikis Club', 'TV-Y7', [10762, 16], 90, 7.8],
  [8002, 'Storybook Street', 'TV-G', [10751], 70, 7.1],
  [8003, 'Teen Drama High', 'TV-14', [18], 85, 7.4],
  [8004, 'Grim Streets', 'TV-MA', [80, 18], 92, 8.4],
  [8005, 'Toon Nights', 'TV-MA', [16, 35], 88, 8.0],
  [8006, 'Mystery Show', '', [16], 60, 6.2],
  [8007, 'Family Fun Hour', 'TV-PG', [10751, 35], 74, 7.0],
  [8008, 'The Detective', 'TV-PG', [80], 72, 7.3]
];

const GENRES = {
  movie: [[28, 'Action'], [12, 'Adventure'], [16, 'Animation'], [35, 'Comedy'], [80, 'Crime'], [14, 'Fantasy'], [27, 'Horror'], [53, 'Thriller'], [10751, 'Family']],
  tv: [[10759, 'Action & Adventure'], [16, 'Animation'], [35, 'Comedy'], [80, 'Crime'], [18, 'Drama'], [10751, 'Family'], [10762, 'Kids']]
};

const movie = (m, i) => ({ id: m[0], title: m[1], overview: 'A story called ' + m[1] + '.', poster_path: '/p' + m[0] + '.jpg', backdrop_path: '/b' + m[0] + '.jpg',
  vote_average: m[5], vote_count: 500, release_date: '2020-0' + (1 + (i % 9)) + '-10', genre_ids: m[3], popularity: m[4], adult: false, certs: m[2], genres: m[3] });
const show = (m, i) => ({ id: m[0], name: m[1], overview: 'A series called ' + m[1] + '.', poster_path: '/p' + m[0] + '.jpg', backdrop_path: '/b' + m[0] + '.jpg',
  vote_average: m[5], vote_count: 500, first_air_date: '2019-0' + (1 + (i % 9)) + '-01', genre_ids: m[3], popularity: m[4], adult: false, rating: m[2], genres: m[3] });
const CAT = { movie: MOVIES.map(movie), tv: SHOWS.map(show) };

const strip = (x, type) => { const { certs, rating, genres, ...rest } = x; return Object.assign(rest, type ? { media_type: type } : {}); };
const page = (items, type) => ({ page: 1, total_pages: 1, total_results: items.length, results: items.map((x) => strip(x, type)) });
const byType = (t) => CAT[t];
const find = (t, id) => byType(t).find((x) => x.id === id);
const rank = (c) => ORDER.indexOf(c);

function genresMatch(item, spec) {
  if (!spec) return true;
  if (spec.includes('|')) return spec.split('|').some((g) => item.genres.includes(Number(g)));
  return spec.split(',').every((g) => item.genres.includes(Number(g)));
}

function discover(type, q) {
  let items = byType(type).filter((x) => genresMatch(x, q.get('with_genres')));
  const lte = q.get('certification.lte');
  if (type === 'movie' && lte) items = items.filter((x) => x.certs.some((c) => rank(c) >= 0 && rank(c) <= rank(lte)));
  const sort = q.get('sort_by') || 'popularity.desc';
  const key = sort.startsWith('vote_average') ? 'vote_average' : 'popularity';
  return items.slice().sort((a, b) => b[key] - a[key]);
}

function details(type, item, url) {
  const append = (url.searchParams.get('append_to_response') || '').split(',');
  const d = Object.assign(strip(item), { genres: item.genres.map((id) => ({ id, name: (GENRES[type].find((g) => g[0] === id) || [id, 'Genre'])[1] })) });
  if (append.includes('credits')) d.credits = { cast: [{ id: 1, name: 'Actor One', character: 'Lead', profile_path: null }], crew: [{ job: 'Director', name: 'Jane Director' }] };
  if (append.includes('videos')) d.videos = { results: [{ site: 'YouTube', type: 'Trailer', official: true, key: 'aqz-KE-bpKQ' }] };
  if (append.includes('recommendations')) d.recommendations = page(byType(type).filter((x) => x.id !== item.id), type);
  if (append.includes('images')) d.images = { logos: [] };
  if (type === 'movie') {
    d.runtime = 96;
    if (append.includes('release_dates')) d.release_dates = releaseDates(item);
  } else {
    d.number_of_seasons = 1;
    d.seasons = [{ season_number: 1, episode_count: 4, name: 'Season 1' }];
    d.episode_run_time = [24];
    if (append.includes('content_ratings')) d.content_ratings = contentRatings(item);
  }
  return d;
}

const releaseDates = (item) => ({ id: item.id, results: [{ iso_3166_1: 'US', release_dates: item.certs.map((c) => ({ certification: c, type: 3 })) }, { iso_3166_1: 'GB', release_dates: [{ certification: '12A', type: 3 }] }] });
const contentRatings = (item) => ({ id: item.id, results: item.rating ? [{ iso_3166_1: 'US', rating: item.rating }, { iso_3166_1: 'GB', rating: '15' }] : [] });

let log = [];

function route(req, url) {
  const p = url.pathname, q = url.searchParams;
  if (p === '/_test/log') return log;
  if (p === '/_test/clear') { log = []; return { ok: true }; }
  log.push(req.url);
  let m;
  if (p === '/3/genre/movie/list' || p === '/3/genre/tv/list') return { genres: GENRES[p.split('/')[3]].map(([id, name]) => ({ id, name })) };
  if ((m = p.match(/^\/3\/trending\/(all|movie|tv)\//))) {
    const t = m[1];
    const items = t === 'all' ? CAT.movie.map((x) => strip(x, 'movie')).concat(CAT.tv.map((x) => strip(x, 'tv'))) : byType(t).map((x) => strip(x, t));
    return { page: 1, results: items };
  }
  if ((m = p.match(/^\/3\/discover\/(movie|tv)$/))) return page(discover(m[1], q), m[1]);
  if (p === '/3/search/multi') {
    const term = (q.get('query') || '').toLowerCase();
    const hits = CAT.movie.filter((x) => x.title.toLowerCase().includes(term)).map((x) => strip(x, 'movie'))
      .concat(CAT.tv.filter((x) => x.name.toLowerCase().includes(term)).map((x) => strip(x, 'tv')));
    if (term) hits.push({ id: 5, media_type: 'person', name: 'Somebody ' + term });
    return { page: 1, results: hits };
  }
  if ((m = p.match(/^\/3\/(movie|tv)\/(popular|now_playing|top_rated|upcoming|on_the_air|airing_today)$/))) return page(byType(m[1]).slice().sort((a, b) => b.popularity - a.popularity), m[1]);
  if ((m = p.match(/^\/3\/tv\/(\d+)\/season\/(\d+)$/))) {
    return { episodes: [1, 2, 3, 4].map((n) => ({ episode_number: n, name: 'Episode ' + n + ' title', overview: 'What happens in episode ' + n + '.', still_path: null, air_date: '2020-01-0' + n, runtime: 24 })) };
  }
  if ((m = p.match(/^\/3\/(movie|tv)\/(\d+)\/release_dates$/))) { const it = find('movie', Number(m[2])); return it ? releaseDates(it) : null; }
  if ((m = p.match(/^\/3\/tv\/(\d+)\/content_ratings$/))) { const it = find('tv', Number(m[1])); return it ? contentRatings(it) : null; }
  if ((m = p.match(/^\/3\/(movie|tv)\/(\d+)\/(recommendations|similar)$/))) {
    const it = find(m[1], Number(m[2]));
    return it ? page(byType(m[1]).filter((x) => x.id !== it.id), m[1]) : null;
  }
  if ((m = p.match(/^\/3\/(movie|tv)\/(\d+)\/images$/))) return { logos: [] };
  if ((m = p.match(/^\/3\/(movie|tv)\/(\d+)$/))) { const it = find(m[1], Number(m[2])); return it ? details(m[1], it, url) : null; }
  if (p.startsWith('/3/person/')) return { results: [], cast: [] };
  return null;
}

http.createServer((req, res) => {
  const out = route(req, new URL(req.url, 'http://x'));
  res.writeHead(out === null ? 404 : 200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(out === null ? { status_message: 'not found' } : out));
}).listen(PORT, '127.0.0.1', () => console.log('mock-tmdb on ' + PORT));

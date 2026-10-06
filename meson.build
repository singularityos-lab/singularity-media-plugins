project('singularity-media-plugins', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-media-plugins"', language: 'c')
add_project_arguments('-w', language: 'c')
subdir('po')

gee_dep  = dependency('gee-0.8')
gio_dep  = dependency('gio-2.0')
json_dep = dependency('json-glib-1.0')
soup_dep = dependency('libsoup-3.0')
peas_dep = dependency('libpeas-2')
xml_dep  = dependency('libxml-2.0')
gtk_dep  = dependency('gtk4')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

plugin_deps = [gee_dep, gio_dep, json_dep, soup_dep, peas_dep, gtk_dep, libsingularity_dep]
app_plugins_dir = get_option('libdir') / 'singularity' / 'app-plugins'

subdir('jellyfin')
subdir('subsonic')
subdir('listenbrainz')
subdir('lrclib')
subdir('musicbrainz')
subdir('spotify')
subdir('nextcloud')
subdir('dlna')
subdir('librespot')
subdir('videos')

media_plugins_test = executable('media-plugins-test',
  files('tests/main.vala', 'tests/mock.vala', 'tests/jellyfin_test.vala', 'tests/subsonic_test.vala', 'tests/metadata_test.vala', 'tests/spotify_test.vala', 'tests/servers_test.vala', 'tests/librespot_test.vala',
        'jellyfin/jellyfin_source.vala', 'subsonic/subsonic_source.vala',
        'listenbrainz/listenbrainz_source.vala', 'lrclib/lrclib_source.vala', 'musicbrainz/musicbrainz_source.vala',
        'spotify/spotify_source.vala', 'nextcloud/nextcloud_source.vala', 'dlna/dlna_source.vala',
        'librespot/librespot_source.vala') + [librespot_config],
  dependencies: plugin_deps + [xml_dep],
  vala_args: ['--pkg', 'posix'],
)
test('media-plugins', media_plugins_test, env: ['GIO_USE_PROXY_RESOLVER=dummy', 'GSETTINGS_BACKEND=memory'])

videos_plugins_test = executable('videos-plugins-test',
  videos_test_sources + files('jellyfin/jellyfin_source.vala', 'dlna/dlna_source.vala', 'tests/mock.vala'),
  dependencies: video_deps, vala_args: video_args)
test('videos-plugins', videos_plugins_test, env: ['GIO_USE_PROXY_RESOLVER=dummy', 'GSETTINGS_BACKEND=memory', 'VIDEOS_FIXTURES=' + meson.current_source_dir() / 'videos' / 'tests' / 'fixtures'])

install_data('data/icons/singularity-lyrics.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps')

executable('videos-live-probe',
  videos_probe_sources + files('tests/mock.vala'),
  dependencies: video_deps, vala_args: video_args)

webkit_dep = dependency('webkitgtk-6.0', required: get_option('embed'))
video_deps = plugin_deps + [xml_dep]
video_args = []
if webkit_dep.found()
  video_deps += [webkit_dep]
  video_args += ['-D', 'HAVE_WEBKIT']
  video_web = static_library('videos-web-player', files('common/web_player.vala'),
    dependencies: video_deps, vala_args: video_args,
    vala_header: 'videos-web-player.h', vala_vapi: 'videos-web-player.vapi', pic: true)
  video_deps += [declare_dependency(link_with: video_web, include_directories: include_directories('.'))]
endif

youtube_sources = files('youtube/youtube_source.vala')
peertube_sources = files('peertube/peertube_source.vala')
nextcloud_videos_sources = files('nextcloud/nextcloud_videos_source.vala')

shared_module('videos-youtube', youtube_sources + files('youtube/register.vala'),
  dependencies: video_deps, vala_args: video_args,
  install: true, install_dir: app_plugins_dir / 'videos' / 'youtube')
configure_file(input: 'youtube/youtube.plugin', output: 'youtube.plugin', copy: true)
install_data('youtube/youtube.plugin', install_dir: app_plugins_dir / 'videos' / 'youtube')

shared_module('videos-peertube', peertube_sources + files('peertube/register.vala'),
  dependencies: video_deps, vala_args: video_args,
  install: true, install_dir: app_plugins_dir / 'videos' / 'peertube')
configure_file(input: 'peertube/peertube.plugin', output: 'peertube.plugin', copy: true)
install_data('peertube/peertube.plugin', install_dir: app_plugins_dir / 'videos' / 'peertube')

shared_module('videos-nextcloud', nextcloud_videos_sources + files('nextcloud/register.vala'),
  dependencies: video_deps, vala_args: video_args,
  install: true, install_dir: app_plugins_dir / 'videos' / 'nextcloud')
configure_file(input: 'nextcloud/nextcloud-videos.plugin', output: 'nextcloud-videos.plugin', copy: true)
install_data('nextcloud/nextcloud-videos.plugin', install_dir: app_plugins_dir / 'videos' / 'nextcloud')

subdir('tests')

videos_probe_sources = youtube_sources + peertube_sources + files('tests/live_probe.vala')
videos_test_sources = youtube_sources + peertube_sources + nextcloud_videos_sources + files('tests/videos_test.vala')

shared_module('media-jellyfin', files('jellyfin_source.vala', 'register.vala'),
  dependencies: plugin_deps,
  install: true, install_dir: app_plugins_dir / 'common' / 'jellyfin')
configure_file(input: 'jellyfin.plugin', output: 'jellyfin.plugin', copy: true)
install_data('jellyfin.plugin', install_dir: app_plugins_dir / 'common' / 'jellyfin')

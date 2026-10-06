librespot_conf = configuration_data()
librespot_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir') / 'singularity')
librespot_config = configure_file(input: 'config.vala.in', output: 'librespot_config.vala', configuration: librespot_conf)

shared_module('media-librespot', files('librespot_source.vala', 'register.vala') + [librespot_config],
  dependencies: plugin_deps,
  vala_args: ['--pkg', 'posix'],
  install: true, install_dir: app_plugins_dir / 'music' / 'librespot')
configure_file(input: 'librespot.plugin', output: 'librespot.plugin', copy: true)
install_data('librespot.plugin', install_dir: app_plugins_dir / 'music' / 'librespot')

librespot_opt = get_option('librespot')
cargo = find_program('cargo', required: false)
if not librespot_opt.disabled() and cargo.found()
  custom_target('librespot-bin',
    output: 'librespot',
    command: [files('build-librespot.sh'), '@OUTPUT@', meson.current_build_dir() / 'cargo', '0.8.0'],
    build_by_default: true,
    console: true,
    install: true,
    install_dir: get_option('libexecdir') / 'singularity')
elif librespot_opt.enabled()
  error('cargo is needed to build librespot')
endif

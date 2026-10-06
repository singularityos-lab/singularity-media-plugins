[ModuleInit]
public void peas_register_types (TypeModule module) {
    ((Peas.ObjectModule) module).register_extension_type (typeof (Singularity.MediaSources.MediaSource), typeof (Singularity.MediaPlugins.NextcloudVideosSource));
}

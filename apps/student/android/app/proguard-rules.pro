# ML Kit discovers these registrars by class name and invokes their no-arg
# constructors through Firebase ComponentDiscovery.
-keep class com.google.mlkit.** implements com.google.firebase.components.ComponentRegistrar {
    <init>();
}

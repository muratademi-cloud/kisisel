# Bildirim için Android ayarlarını yapar (izinler, alıcılar, desugaring).
import pathlib, re, sys

man = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = man.read_text(encoding='utf-8')

perms = '''    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <uses-permission android:name="android.permission.VIBRATE"/>
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.USE_EXACT_ALARM"/>
'''
receivers = '''        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
'''
if '<application' not in s or '</application>' not in s:
    sys.exit('AndroidManifest.xml beklenen biçimde değil')
s = s.replace('<application', perms + '    <application', 1)
s = s.replace('</application>', receivers + '    </application>', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="Kişisel Takip"', s, count=1)
man.write_text(s, encoding='utf-8')

for name in ('android/app/build.gradle.kts', 'android/app/build.gradle'):
    f = pathlib.Path(name)
    if f.exists():
        break
else:
    sys.exit('build.gradle bulunamadı')

g = f.read_text(encoding='utf-8')
kts = name.endswith('.kts')
if 'compileOptions' not in g:
    sys.exit('compileOptions bulunamadı')

if kts:
    g = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', g, count=1)
    g = re.sub(r'(buildTypes\s*\{\s*(?:getByName\("release"\)|release)\s*\{)',
               r'\1\n            isMinifyEnabled = false\n            isShrinkResources = false', g, count=1)
    g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
else:
    g = re.sub(r'compileOptions\s*\{', 'compileOptions {\n        coreLibraryDesugaringEnabled true', g, count=1)
    g = re.sub(r'(buildTypes\s*\{\s*release\s*\{)',
               r'\1\n            minifyEnabled false\n            shrinkResources false', g, count=1)
    g += '\ndependencies {\n    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.1.4"\n}\n'
f.write_text(g, encoding='utf-8')
print('Android ayarları tamam:', name)

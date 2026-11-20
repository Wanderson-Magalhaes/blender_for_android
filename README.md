<!--
Keep this document short & concise,
linking to external resources instead of including content in-line.
See 'release/text/readme.html' for the end user read-me.
-->

# Blender for Android

**An unofficial fork of Blender, ported to Android. arm64, Vulkan, built and
tested on a Galaxy S24 Ultra.**

![Blender screenshot](https://code.blender.org/wp-content/uploads/2018/12/springrg.jpg "Blender screenshot")

## Demonstration

[![Watch the Android demo on YouTube](https://img.youtube.com/vi/qzdrdLbK7Kw/hqdefault.jpg)](https://www.youtube.com/watch?v=qzdrdLbK7Kw)

[Watch the Android demonstration on YouTube](https://www.youtube.com/watch?v=qzdrdLbK7Kw)

## A study project

This started as a way to learn, and that is what it stayed. It is not
maintained, and there is no active support behind it: an open source project
deserves time that I do not have right now, and saying so plainly beats leaving
people waiting for an answer that is not coming.

It is public because it works, and because some of what is in here might be
useful to someone. The on-screen keyboard, for example, is a native one drawn by
Blender itself that sends real key events, so it types into any field, holds
Ctrl, Shift and Alt, and fires every shortcut in the keymap. If any of this is
worth something to the Blender developers, or to anyone porting Blender to a
touch device, take it.

Anyone who wants it for study is welcome to download it, build it and
contribute. Nothing here is waiting on permission.

One warning: this tree does not follow Blender's own structure everywhere. It
carries a lot of experiments, and some of them left marks. Read it as a
sketchbook, not as a reference implementation.

## Reporting bugs

Use the [Android bug report form](https://github.com/Wanderson-Magalhaes/blender_for_android/issues/new?template=01_android_bug.yml) for APKs downloaded from this repository's Releases. Include the download link, exact APK name, build variant, device model, GPU, and Android version. For APKs from @idimus (a.k.a. simfeo) or other forks, use their project's reporting channels.

The Galaxy S24 Ultra (Adreno 750) is currently the only device available to reproduce bugs and verify fixes. Reports from other devices are welcome as compatibility feedback, with limited support.

## Credits

This port did not start with me. It started with [**@idimus**](https://www.reddit.com/user/idimus/)
(a.k.a. simfeo), who did the hard bring up work, and whose release is
the build this fork was derived from:

- <https://github.com/simfeo/blender/releases/tag/android-alpha-1>
- @idimus / simfeo's releases: <https://github.com/simfeo/blender/releases>

And of course **Blender** itself, made and maintained by the Blender Foundation
and its community. None of this exists without them.

The adjustments in this fork are by **Wanderson M. Pimenta**.

## About the code

I am new to C++. I wrote my first line of code 19 years ago, but this port was
my first real experience with the language, against a codebase far larger than
me. **ChatGPT Sol** and **Claude Opus 5** are what made it possible: they carried
the cross compilation of dependency after dependency and a great deal of the
debugging. Without them I would not have had the time to even run these
experiments, let alone finish them.

## Building and installing

Everything you need is in **[ANDROID\_AI\_GUIDE.md](ANDROID_AI_GUIDE.md)**:
prerequisites, the dependency build, the two feature sets, the flags that
matter, the traps that end in a build that looks fine while the device runs old
code, how to drive a device over ADB, and a map of every change with a link to
the file it lives in.

## License

Blender is licensed under the GNU General Public License, Version 3, and this
fork inherits it. If you distribute a binary built from this tree, the matching
source has to go with it.

***

Everything below is the upstream Blender read-me.

Blender is the free and open source 3D creation suite.
It supports the entirety of the 3D pipeline, modeling, rigging, animation, simulation, rendering, compositing,
motion tracking and video editing.

## Project Pages

- [Main Website](https://www.blender.org)
- [Reference Manual](https://docs.blender.org/manual/en/latest/index.html)
- [User Community](https://www.blender.org/community/)

## Development

- [Build Instructions](https://developer.blender.org/docs/handbook/building_blender/)
- [Code Review & Bug Tracker](https://projects.blender.org)
- [Developer Forum](https://devtalk.blender.org)
- [Developer Documentation](https://developer.blender.org/docs/)

## License

Blender as a whole is licensed under the GNU General Public License, Version 3.
Individual files may have a different but compatible license.

See [blender.org/about/license](https://www.blender.org/about/license) for details.

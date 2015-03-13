
use deadlogger
import deadlogger/[Log, Level, Logger, Formatter, Handler]

use bloop
import bloop/bloop

import os/Time

setupLog: func {
    console := StdoutHandler new()
    console setFormatter(ColoredFormatter new(NiceFormatter new()))
    console level = Level info
    Log root attachHandler(console)
}

main: func -> Int {
    setupLog()
    logger := Log getLogger("simple")

    box := Boombox new()

    music := box load("music.ogg", true)
    musicSource := box loop(music)
    musicSource gain = 0.2

    sample := box load("test.ogg", true)
    source := box play(sample)
    source autofree = false

    counter := 0
    doUpdate := func {
        Time sleepMilli(16)
        box update()
        counter += 1
        if (counter > 2) {
            counter = 0
            logger info("#{source currentTime} / #{sample duration}")
        }
    }

    logger warn("playing first segment")
    while (source currentTime < 1.15) {
        doUpdate()
    }

    logger warn("seeking forward")
    source seek(7.9)
    while (source currentTime < 8.9) {
        doUpdate()
    }

    source pause()
    logger warn("pausing for a second")
    wait := 120
    while ((wait -= 1) > 0) {
        doUpdate()
    }

    logger warn("playing till end")
    source play()
    while (source playing) {
        doUpdate()
    }

    logger warn("playing a bit from beginning")
    source play()
    while (source currentTime < 2.9) {
        doUpdate()
    }

    logger warn("seeking backwards")
    source seek(1.5)
    source play()
    while (source currentTime < 5) {
        doUpdate()
    }

    logger warn("seeking forward")
    source seek(7.5)
    source play()
    while (source playing) {
        doUpdate()
    }

    logger warn("Final time: #{source currentTime}")

    box destroy()

}


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

main: func {
    setupLog()
    logger := Log getLogger("simple")

    box := Boombox new()

    sample := box load("test.ogg", true)
    source := box play(sample)
    counter := 0

    while (source playing) {
        Time sleepMilli(16)
        box update()
        counter += 1
        if (counter > 10) {
            counter = 0
            logger info("#{source currentTime} / #{sample duration}")
        }
    }

    box destroy()

}

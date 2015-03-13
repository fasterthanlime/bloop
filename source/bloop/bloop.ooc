
use    openal, vorbis, deadlogger
import openal, vorbis, os/Time, io/File, structs/[ArrayList, HashMap, List], deadlogger/Log

SourceState: enum {
    STOPPED
    PLAYING
}

Source: class {

    boombox: Boombox
    sample: Sample
    autofree: Bool
    loop := false
    playing := false
    paused := false
    currentTime: Double = 0

    BURST := static 64
    LOW := static 4

    sourceID: ALuint // OpenAL sound source ID

    init: func (=boombox, =sample, =autofree) {
        alGenSources(1, sourceID&)
        alSource3f(sourceID, AL_POSITION, 0.0, 0.0, 0.0)
        alSourcei(sourceID, AL_REFERENCE_DISTANCE, 1.0)
        alSourcei(sourceID, AL_MAX_DISTANCE, 1000.0)

        if (!sample streaming) {
            log("Queuing #{sample bufferIDs size} buffers")
            queueAll(sample bufferIDs)
        }
    }

    gain: Float {
        set (gain) {
            alSourcef(sourceID, AL_GAIN, gain)
        }

        get {
            gain: Float
            alGetSourcef(sourceID, AL_GAIN, gain&)
            gain
        }
    }

    unqueue: func (bufferID: ALuint) {
        bytes: ALint = 0;
        chans: ALint = 0;
        bits: ALint = 0;
        alGetBufferi(bufferID, AL_SIZE, bytes&)
        alGetBufferi(bufferID, AL_CHANNELS, chans&)
        alGetBufferi(bufferID, AL_BITS, bits&)

        lengthInSamples := bytes * 8 / (chans * bits)
        
        freq: ALint = 0;
        alGetBufferi(bufferID, AL_FREQUENCY, freq&)

        durationInSeconds := (lengthInSamples as Double) / (freq as Double)

        currentTime += durationInSeconds
        alSourceUnqueueBuffers(sourceID, 1, bufferID&)
        if (err := alGetError()) {
            raise("Error while unqueuing buffer #{bufferID}: #{alGetString(err)}")
        }
    }

    queue: func (bufferID: ALuint) {
        alSourceQueueBuffers(sourceID, 1, bufferID&)
        if (err := alGetError()) {
            raise("Error while queuing buffer: #{alGetString(err)}")
        }
    }

    queueAll: func (bufferIDs: ArrayList<ALuint>) {
        // FIXME: use alSourceQueue buffers instead, e.g:
        //alSourceQueueBuffers(sourceID, bufferIDs size, bufferIDs toArray())

        bufferIDs each(|bi| queue(bi))
    }

    getState: func -> SourceState {
        // Query the state of the souce
        als: ALint = 0
        alGetSourcei(sourceID, AL_SOURCE_STATE, als&)
        match als {
            case AL_STOPPED => SourceState STOPPED
            case            => SourceState PLAYING
        }
    }

    update: func {
        if (paused || !playing) { return }

        if (sample streaming) {
            processed: Int
            alGetSourcei(sourceID, AL_BUFFERS_PROCESSED, processed&)

            if (!sample hasNext) {
                queued: Int
                alGetSourcei(sourceID, AL_BUFFERS_QUEUED, queued&)

                if (processed == queued) {
                    playing = false
                    paused = false
                    alSourceStop(sourceID)
                    log("finished playing #{sample path}")
                } else {
                    if (processed > Source LOW) {
                        refill(processed)
                    }
                }
            } else {
                if (processed > Source LOW) {
                    refill(processed)
                }
            }
        }

        if(getState() == SourceState STOPPED) {
            playing = false
            refill(0, 0)

            if(autofree) {
                log("Freeing because stopped")
                boombox freeSource(this)
                return
            }
            
            if (loop) {
                log("Looping")
                play()
            }
        }
    }

    log: func (msg: String) {
        Boombox logger debug("[#{sourceID}] #{msg}")
    }

    refill: func (processed: Int, queueing := -1) {
        if (queueing == -1) {
            queueing = BURST - processed
        }
        log("Processed #{processed}, queueing #{queueing}")
        sample refill(processed, queueing, |bufferID|
            unqueue(bufferID)
            , |bufferID|
            queue(bufferID)
        )
    }

    play: func {
        if (playing) {
            return
        }

        if (paused) {
            paused = false
            log("[Source %d] resuming" format(sourceID))
        } else {
            seek(0)
            log("[Source %d] playing" format(sourceID))
        }

        playing = true

        alSourcePlay(sourceID)
    }

    pause: func () {
        if (paused || !playing) { return }

        log("[Source %d] pausing" format(sourceID))
        paused = true
        playing = false
        alSourcePause(sourceID)
    }

    free: func {
        alSourceStop(sourceID)
        alDeleteSources(1, sourceID&)
    }

    seek: func (time: Double) {
        log("Seeking to #{time}")
        alSourceStop(sourceID)

        queued: Int
        alGetSourcei(sourceID, AL_BUFFERS_QUEUED, queued&)
        sample refill(queued, 0, |bufferID| unqueue(bufferID), |bufferID|)

        processed: Int
        alGetSourcei(sourceID, AL_BUFFERS_PROCESSED, processed&)
        if (processed > 0) {
            raise("After seek, should have 0 processed buffers")
        }
        alGetSourcei(sourceID, AL_BUFFERS_QUEUED, queued&)
        if (processed > 0) {
            raise("After seek, should have 0 queued buffers")
        }

        sample seek(time)

        currentTime = time

        refill(0)
        alGetSourcei(sourceID, AL_BUFFERS_QUEUED, queued&)

        if (playing || paused) {
            alSourcePlay(sourceID)
            if (paused) {
                alSourcePause(sourceID)
            }
        }
    }

}

TINY_BUFFER_SIZE := 4096

// a sound loaded from a file
Sample: class {
    bufferIDs := ArrayList<ALuint> new()
    format: ALformat
    freq: ALsizei
    duration: Double = -1

    path: String
    streaming: Bool

    // internal state
    fstream: FStream
    endian: Int
    oggFile: _OggFile*
    pInfo: VorbisInfo*
    buffer: Char*
    hasNext := true

    // loads the sample
    init: func (=path, =streaming) {
        if (!path endsWith?(".ogg")) {
            raise("Could not load #{path}, unknown format (only OGG is supported)")
        }

        if (streaming) {
            open()
        } else {
            preload()
        }
    }

    preload: func {
        open()
        while (hasNext) {
            decodeFrame()
        }
        //close()
    }

    open: func {
        endian = 0 // 0 for little endian, 1 for big endian

        // Open for binary reading
        fstream = fopen(path, "rb")
        if (!fstream) {
            raise("Cannot open #{path} for reading...")
        }

        // Try opening the given file
        oggFile = gc_malloc(_OggFile size)
        if (ov_open(fstream, oggFile, null, 0) != 0) {
            raise("Cannot open #{path} for decoding...")
        }

        // Get some information about the OGG file
        pInfo = ov_info(oggFile, -1)

        // Check the number of channels... always use 16-bit samples
        format = (pInfo@ channels == 1) ?
        ALformat mono16 :
        ALformat stereo16

        // The frequency of the sampling rate
        freq = pInfo@ rate

        // initialize buffer
        buffer = gc_malloc(TINY_BUFFER_SIZE)

        // also get the duration while we're at it
        duration = ov_time_total(oggFile, -1)
    }

    refill: func (processed, required: Int, unqueue: Func (ALuint), queue: Func (ALuint)) {
        // TODO: don't delete buffers, stupid!
        for (i in 0..processed) {
            bufferID := bufferIDs removeAt(0)
            unqueue(bufferID)
            alDeleteBuffers(1, bufferID&)
            if (err := alGetError()) {
                raise("Error while deleting buffer: #{alGetString(err)}")
            }
        }

        if (hasNext) {
            for (i in 0..required) {
                bufferID := decodeFrame()
                if (bufferID != -1) {
                    queue(bufferID)
                }
            }
        }
    }

    decodeFrame: func -> ALuint {
        if (!hasNext) {
            return -1
        }

        bitStream: Int = 0
        bytes := ov_read(oggFile, buffer, TINY_BUFFER_SIZE, endian, 2, 1, bitStream&)

        match {
            case bytes > 0 =>
                // create a new buffer
                bufferID: ALuint = -1
                alGenBuffers(1, bufferID&)
                alBufferData(bufferID, format, buffer, bytes, freq)
                bufferIDs add(bufferID)
                bufferID
            case bytes < 0 =>
                // something wrong happened
                close()
                hasNext = false
                raise("Error decoding #{path}...")
                -1
            case =>
                // end of file!
                hasNext = false
                -1
        }

    }

    seek: func (time: Double) {
        if(ov_time_seek(oggFile, time)) {
            raise("Could not seek inside #{path}")
        }
        hasNext = true
        while (!bufferIDs empty?()) {
            bufferID := bufferIDs removeAt(0)
            alDeleteBuffers(1, bufferID&)
        }
    }

    close: func {
        // Clean up!
        gc_free(buffer)
        ov_clear(oggFile)
    }

    // free: func {
    //     alDeleteBuffers(bufferIDs size, bufferIDs toArray())
    // }

}

// a sound system :D
Boombox: class {

    ctx: ALCContext
    dev: ALCDevice

    logger := static Log getLogger("boombox")
    cache := HashMap<String, Sample> new()
    sources := ArrayList<Source> new()

    init: func {
        // Initialize the OpenAL library
        dev = alcOpenDevice(null)
        if (!dev) {
            raise("Could not open OpenAL device")
        }

        ctx = alcCreateContext(dev, null)
        if (!ctx) {
            raise("Could not create OpenAL context")
        }
        alcMakeContextCurrent(ctx)

        alListener3f(AL_POSITION, 0.0, 0.0, 0.0)
        logger info("Sound system initialized")
    }

    load: func (path: String, streaming := false) -> Sample {
        aPath := File new(path) getAbsolutePath()
        if (cache contains?(aPath)) {
            cache get(aPath)
        } else {
            logger debug("Loading audio file... %s" format(path))
            s := Sample new(aPath, streaming)
            if (!streaming) {
                cache put(aPath, s)
            }
            s
        }
    }

    update: func {
        i := 0
        while (i < sources size) {
            // weird way to iterate because we remove sources
            sources[i] update()
            i += 1
        }
    }

    loop: func (s: Sample) -> Source {
        src := Source new(this, s, false)
        sources add(src)
        src loop = true
        src play()
        src
    }

    play: func (s: Sample) -> Source {
        src := Source new(this, s, true)
        sources add(src)
        src play()
        src
    }

    freeSource: func (src: Source) {
        Boombox logger info("Freeing source #{src sourceID}")
        src free()
        sources remove(src)
    }

    destroy: func {
        // Clean up the OpenAL library
        alcMakeContextCurrent(null)
        alcDestroyContext(ctx)
        alcCloseDevice(dev)
    }

}


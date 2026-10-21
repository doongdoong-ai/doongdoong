#!/usr/bin/env python3
"""File-only WebRTC transport. Authentication and app-server RPC belong to Swift.

One transport session per process; newline-delimited JSON-RPC on stdin/stdout.
This process never requests a microphone, opens an audio output, or launches UI.
"""

import asyncio
from fractions import Fraction
import json
import logging
import math
from pathlib import Path
import signal
import sys
import time
import wave

from aiortc import AudioStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from av import AudioFrame


logging.disable(logging.CRITICAL)
EVENT_TYPES = frozenset(("input_transcript.added", "turn.done", "session.started", "error"))
MAX_MESSAGE_BYTES = 1024 * 1024


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class FileAudioTrack(AudioStreamTrack):
    """Read one 20 ms PCM frame at a time, then send silence until stopped."""

    def __init__(self, audio_path, ready, notify):
        super().__init__()
        self.ready = ready
        self.notify = notify
        self.source = None
        self.position = 0
        self.file_position = 0
        self.started_at = None
        self.ended = False
        try:
            path = Path(audio_path)
            if not path.is_file() or path.suffix.lower() != ".wav":
                raise RPCError(-32602, "audioPath must name a regular WAV file")
            self.source = wave.open(str(path), "rb")
            if self.source.getnchannels() != 1 or self.source.getsampwidth() != 2 or self.source.getcomptype() != "NONE":
                raise RPCError(-32602, "Audio must be mono 16-bit PCM WAV")
            self.sample_rate = self.source.getframerate()
            if self.sample_rate not in (16000, 48000):
                raise RPCError(-32602, "Audio sample rate must be 16000 or 48000 Hz")
            self.file_samples = self.source.getnframes()
            self.duration = self.file_samples / self.sample_rate
            if self.file_samples <= 0 or not math.isfinite(self.duration):
                raise RPCError(-32602, "Audio file is empty")
            self.frame_samples = self.sample_rate // 50
            self.frame_bytes = self.frame_samples * 2
        except RPCError:
            self.stop()
            raise
        except (OSError, EOFError, wave.Error):
            self.stop()
            raise RPCError(-32602, "Cannot read the PCM WAV file")

    async def recv(self):
        await self.ready.wait()
        if self.readyState != "live":
            raise MediaStreamError
        if self.started_at is None:
            self.started_at = time.monotonic()
        await asyncio.sleep(max(0, self.started_at + self.position / self.sample_rate - time.monotonic()))
        if self.readyState != "live":
            raise MediaStreamError
        chunk = b""
        if self.source is not None:
            try:
                chunk = self.source.readframes(self.frame_samples)
            except (OSError, EOFError, wave.Error):
                self.notify("transport/event", {"event": {"type": "error", "error": {"code": "audio_read_failed", "message": "Could not read an audio frame"}}})
                self.stop()
                raise MediaStreamError
            self.file_position += len(chunk) // 2
            if len(chunk) == 0 and self.file_position < self.file_samples:
                self.notify("transport/event", {"event": {"type": "error", "error": {"code": "audio_truncated", "message": "The WAV file ended before its declared duration"}}})
                self.stop()
                raise MediaStreamError
        frame = AudioFrame(format="s16", layout="mono", samples=self.frame_samples)
        frame.planes[0].update(chunk.ljust(self.frame_bytes, b"\0"))
        frame.sample_rate = self.sample_rate
        frame.pts = self.position
        frame.time_base = Fraction(1, self.sample_rate)
        if self.position == 0:
            self.notify("transport/mediaStarted", {})
        self.position += self.frame_samples
        if not self.ended and self.file_position >= self.file_samples:
            self.ended = True
            if self.source is not None:
                self.source.close()
                self.source = None
            self.notify("transport/mediaEnded", {})
        return frame

    def stop(self):
        super().stop()
        if self.source is not None:
            self.source.close()
            self.source = None
        self.ready.set()


class Transport:
    def __init__(self):
        self.peer = None
        self.track = None
        self.ready = asyncio.Event()
        self.channel_open = asyncio.Event()
        self.stopped = asyncio.Event()
        self.phase = "idle"
        self.deadline = time.monotonic() + 60
        self.tasks = set()
        self.output_open = True

    def send(self, value):
        if not self.output_open:
            return
        try:
            sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            self.output_open = False
            self.stopped.set()

    def notify(self, method, params):
        self.send({"method": method, "params": params})

    async def start(self, params):
        if self.phase != "idle":
            raise RPCError(-32000, "A transport session has already been started")
        path = params.get("audioPath")
        if not isinstance(path, str) or not path:
            raise RPCError(-32602, "audioPath is required")
        self.ready = asyncio.Event()
        self.track = FileAudioTrack(path, self.ready, self.notify)
        self.phase = "starting"
        self.peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.peer.addTrack(self.track)
        channel = self.peer.createDataChannel("oai-events", ordered=True)

        @channel.on("open")
        def on_open():
            self.channel_open.set()

        @channel.on("message")
        def on_message(message):
            if not isinstance(message, str) or len(message) > MAX_MESSAGE_BYTES:
                return
            try:
                event = json.loads(message)
                if isinstance(event, dict) and event.get("type") in EVENT_TYPES:
                    self.notify("transport/event", {"event": event})
            except (ValueError, TypeError):
                return

        @self.peer.on("connectionstatechange")
        async def on_connection_state():
            if self.peer.connectionState == "failed" and self.phase != "stopping":
                self.notify("transport/event", {"event": {"type": "error", "error": {"code": "connection_failed", "message": "WebRTC connection failed"}}})
                self.stopped.set()

        @self.peer.on("track")
        def on_remote_track(remote_track):
            # Discard remote audio frames; never create an output device or let a
            # received-audio queue grow when the server uses audio output mode.
            async def discard():
                try:
                    while True:
                        await remote_track.recv()
                except MediaStreamError:
                    pass
            task = asyncio.create_task(discard())
            self.tasks.add(task)
            task.add_done_callback(self.tasks.discard)

        try:
            offer = await asyncio.wait_for(self.peer.createOffer(), 15)
            await asyncio.wait_for(self.peer.setLocalDescription(offer), 15)
        except asyncio.TimeoutError:
            raise RPCError(-32001, "Timed out creating the WebRTC offer")
        self.phase = "offered"
        self.deadline = time.monotonic() + 60
        return {"sdp": self.peer.localDescription.sdp, "duration": self.track.duration}

    async def answer(self, params):
        if self.phase != "offered":
            raise RPCError(-32000, "Create an offer before applying an answer")
        sdp = params.get("sdp")
        if not isinstance(sdp, str) or not sdp.startswith("v=0"):
            raise RPCError(-32602, "A valid SDP answer is required")
        self.phase = "answering"
        try:
            await asyncio.wait_for(self.peer.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="answer")), 15)
            await asyncio.wait_for(self.channel_open.wait(), 25)
        except asyncio.TimeoutError:
            raise RPCError(-32001, "Timed out opening the WebRTC data channel")
        self.phase = "connected"
        self.deadline = time.monotonic() + 60
        return {}

    async def play(self, params):
        if self.phase != "connected":
            raise RPCError(-32000, "Apply the answer and open the data channel before playback")
        self.phase = "playing"
        # A bounded silence tail is a cleanup backstop, not a transcription deadline.
        self.deadline = time.monotonic() + self.track.duration + 120
        # The response is written synchronously before the event loop delivers frames.
        asyncio.get_running_loop().call_soon(self.ready.set)
        return {}

    async def handle(self, message):
        request_id = message.get("id")
        if "id" not in message:
            return
        try:
            method = message.get("method")
            params = message.get("params", {})
            if not isinstance(params, dict):
                raise RPCError(-32602, "params must be an object")
            if method == "transport/start":
                result = await self.start(params)
            elif method == "transport/answer":
                result = await self.answer(params)
            elif method == "transport/play":
                result = await self.play(params)
            elif method == "transport/stop":
                self.phase = "stopping"
                result = {}
                self.stopped.set()
            else:
                raise RPCError(-32601, "Unknown transport method")
            self.send({"id": request_id, "result": result})
        except RPCError as error:
            self.send({"id": request_id, "error": {"code": error.code, "message": error.message}})
            if self.phase in ("starting", "answering"):
                self.stopped.set()
        except asyncio.CancelledError:
            raise
        except Exception:
            # Do not expose arbitrary library exception strings, SDP, or credentials.
            self.send({"id": request_id, "error": {"code": -32603, "message": "Audio transport operation failed"}})
            self.stopped.set()

    async def read_requests(self):
        reader = asyncio.StreamReader(limit=MAX_MESSAGE_BYTES)
        protocol = asyncio.StreamReaderProtocol(reader)
        pipe, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
        try:
            while not self.stopped.is_set():
                try:
                    line = await reader.readline()
                except ValueError:
                    self.send({"id": None, "error": {"code": -32600, "message": "Request exceeds the size limit"}})
                    break
                if not line:
                    break
                try:
                    message = json.loads(line)
                    if not isinstance(message, dict):
                        raise ValueError
                except (ValueError, UnicodeDecodeError):
                    self.send({"id": None, "error": {"code": -32700, "message": "Invalid JSON request"}})
                    continue
                task = asyncio.create_task(self.handle(message))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
        finally:
            pipe.close()
            self.stopped.set()

    async def watchdog(self):
        while not self.stopped.is_set():
            if time.monotonic() >= self.deadline:
                self.notify("transport/event", {"event": {"type": "error", "error": {"code": "transport_timeout", "message": "Audio transport exceeded its session deadline"}}})
                self.stopped.set()
                return
            await asyncio.sleep(1)

    async def close(self):
        self.phase = "stopping"
        if self.track is not None:
            self.track.stop()
        if self.peer is not None:
            try:
                await asyncio.wait_for(self.peer.close(), 5)
            except (Exception, asyncio.CancelledError):
                pass

    async def run(self):
        loop = asyncio.get_running_loop()
        for name in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(name, self.stopped.set)
        reader_task = asyncio.create_task(self.read_requests())
        watchdog_task = asyncio.create_task(self.watchdog())
        try:
            await self.stopped.wait()
        finally:
            reader_task.cancel()
            watchdog_task.cancel()
            pending = list(self.tasks)
            for task in pending:
                task.cancel()
            await asyncio.gather(reader_task, watchdog_task, *pending, return_exceptions=True)
            await self.close()


async def main():
    # Python 3.9 binds asyncio primitives to the current loop at construction.
    await Transport().run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    except Exception:
        # stdout remains exclusively the protocol; stderr never contains a traceback.
        sys.exit(1)

# Third-party notices

Terminal Relay includes the following Swift packages:

- Sparkle 2.9.2 — MIT License
- SwiftTerm 1.15.0 — MIT License
- SwiftNIO SSH 0.14.1 — Apache License 2.0
- SwiftNIO 2.101.3 — Apache License 2.0
- Swift Crypto 4.5.1 — Apache License 2.0
- Swift Collections 1.6.0 — Apache License 2.0
- Swift System 1.7.5 — Apache License 2.0
- Swift Atomics 1.3.1 — Apache License 2.0
- Swift ASN.1 1.7.1 — Apache License 2.0
- Swift Argument Parser 1.8.2 — Apache License 2.0

The Apache-licensed components are distributed under the repository's
[Apache License 2.0](LICENSE).

Worker installation also creates a root-owned Python environment for the
official Claude Agent SDK. The exact versions are pinned in
`Server/claude-agent-sdk-requirements.txt`; their wheel metadata declares:

- annotated-types 0.7.0 — MIT License
- anyio 4.14.2 — MIT License
- attrs 26.1.0 — MIT License
- certifi 2026.7.22 — Mozilla Public License 2.0
- cffi 2.1.0 — MIT No Attribution License
- claude-agent-sdk 0.2.125 — MIT License
- click 8.4.2 — BSD 3-Clause License
- cryptography 49.0.0 — Apache License 2.0 or BSD 3-Clause License
- h11 0.16.0 — MIT License
- httpcore 1.0.9 — BSD 3-Clause License
- httpx 0.28.1 — BSD 3-Clause License
- httpx-sse 0.4.3 — MIT License
- idna 3.18 — BSD 3-Clause License
- jsonschema 4.26.0 — MIT License
- jsonschema-specifications 2025.9.1 — MIT License
- mcp 1.28.1 — MIT License
- pycparser 3.0 — BSD 3-Clause License
- pydantic 2.13.4 — MIT License
- pydantic-core 2.46.4 — MIT License
- pydantic-settings 2.14.2 — MIT License
- PyJWT 2.13.0 — MIT License
- python-dotenv 1.2.2 — BSD 3-Clause License
- python-multipart 0.0.32 — Apache License 2.0
- referencing 0.37.0 — MIT License
- rpds-py 2026.6.3 — MIT License
- sniffio 1.3.1 — MIT License or Apache License 2.0
- sse-starlette 3.4.6 — BSD 3-Clause License
- starlette 1.3.1 — BSD 3-Clause License
- typing-inspection 0.4.2 — MIT License
- typing-extensions 4.16.0 — Python Software Foundation License 2.0
- uvicorn 0.51.0 — BSD 3-Clause License

Those distributions retain their license and notice files inside the installed
environment. Terminal Relay does not vendor their source into this repository.

Sparkle is distributed under the following terms:

> Copyright (c) 2006-2013 Andy Matuschak.
>
> Copyright (c) 2009-2013 Elgato Systems GmbH.
>
> Copyright (c) 2011-2014 Kornel Lesiński.
>
> Copyright (c) 2015-2017 Mayur Pawashe.
>
> Copyright (c) 2014 C.W. Betts.
>
> Copyright (c) 2014 Petroules Corporation.
>
> Copyright (c) 2014 Big Nerd Ranch.
>
> All rights reserved.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

SwiftTerm is distributed under the following terms:

> Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
>
> Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
>
> Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
>
> Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

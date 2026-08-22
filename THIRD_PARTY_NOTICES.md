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
- MarkdownView 3.0.0 — MIT License
- RichText 1.0.0 — MIT License
- Highlightr 2.3.0 — MIT License
- highlight.js 11.11.1, bundled by Highlightr — BSD 3-Clause License
- swift-markdown 0.8.0 — Apache License 2.0
- swift-cmark 0.8.0 — BSD-style License with MIT-licensed derived portions

MarkdownView is configured without its optional LaTeX trait, so Terminal Relay
does not include SwiftMath.

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

Sparkle additionally bundles the following externally licensed components,
whose notices its license requires reproducing in binary redistributions:

> EXTERNAL LICENSES
> =================
>
> bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:
>
> Copyright 2003-2005 Colin Percival
> All rights reserved
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted providing that the following conditions
> are met:
> 1. Redistributions of source code must retain the above copyright
>    notice, this list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright
>    notice, this list of conditions and the following disclaimer in the
>    documentation and/or other materials provided with the distribution.
>
> THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
> IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
> WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
> ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
> DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
> DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
> OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
> HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
> STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
> IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.
>
> --
>
> sais.c and sais.h, from sais-lite (2010/08/07)
> <https://sites.google.com/site/yuta256/sais>:
>
> The sais-lite copyright is as follows:
>
> Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.
>
> Permission is hereby granted, free of charge, to any person
> obtaining a copy of this software and associated documentation
> files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use,
> copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following
> conditions:
>
> The above copyright notice and this permission notice shall be
> included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
> EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
> OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
> HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
> WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
> FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
> OTHER DEALINGS IN THE SOFTWARE.
>
> --
>
> Portable C implementation of Ed25519, from https://github.com/orlp/ed25519
>
> Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>
>
> This software is provided 'as-is', without any express or implied warranty.
> In no event will the authors be held liable for any damages arising from the
> use of this software.
>
> Permission is granted to anyone to use this software for any purpose,
> including commercial applications, and to alter it and redistribute it
> freely, subject to the following restrictions:
>
> 1. The origin of this software must not be misrepresented; you must not
>    claim that you wrote the original software. If you use this software in a
>    product, an acknowledgment in the product documentation would be
>    appreciated but is not required.
>
> 2. Altered source versions must be plainly marked as such, and must not be
>    misrepresented as being the original software.
>
> 3. This notice may not be removed or altered from any source distribution.
>
> --
>
> SUSignatureVerifier.m:
>
> Copyright (c) 2011 Mark Hamlin.
>
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted providing that the following conditions
> are met:
> 1. Redistributions of source code must retain the above copyright
>    notice, this list of conditions and the following disclaimer.
> 2. Redistributions in binary form must reproduce the above copyright
>    notice, this list of conditions and the following disclaimer in the
>    documentation and/or other materials provided with the distribution.
>
> THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
> IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
> WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
> ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
> DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
> DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
> OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
> HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
> STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
> IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

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

highlight.js, bundled by Highlightr, is distributed under the following terms:

> BSD 3-Clause License
>
> Copyright (c) 2006, Ivan Sagalaev.
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
>
> * Redistributions of source code must retain the above copyright notice, this
>   list of conditions and the following disclaimer.
>
> * Redistributions in binary form must reproduce the above copyright notice,
>   this list of conditions and the following disclaimer in the documentation
>   and/or other materials provided with the distribution.
>
> * Neither the name of the copyright holder nor the names of its
>   contributors may be used to endorse or promote products derived from
>   this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
> AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
> IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
> DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
> FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
> DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
> SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
> CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
> OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
> OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Apache License 2.0 attribution notices

The following NOTICE file contents accompany the Apache-licensed packages
bundled in Terminal Relay's distributed binaries, as required by section 4(d)
of the Apache License 2.0.

### SwiftNIO

> The SwiftNIO Project
>
> Please visit the SwiftNIO web site for more information:
> https://github.com/apple/swift-nio
>
> Copyright 2017, 2018 The SwiftNIO Project
>
> The SwiftNIO Project licenses this file to you under the Apache License,
> version 2.0 (the "License"); you may not use this file except in compliance
> with the License. You may obtain a copy of the License at:
> https://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations
> under the License.
>
> Also, please refer to each LICENSE.<component>.txt file, which is located in
> the 'license' directory of the distribution file, for the license terms of
> the components that this product depends on.
>
> This product is heavily influenced by Netty (Apache License 2.0,
> https://netty.io).
>
> This product contains NodeJS's llhttp (MIT,
> https://github.com/nodejs/llhttp).
>
> This product contains "cpp_magic.h" from Thomas Nixon & Jonathan Heathcote's
> uSHET (MIT, https://github.com/18sg/uSHET).
>
> This product contains "sha1.c" and "sha1.h" from FreeBSD (Copyright (C) 1995,
> 1996, 1997, and 1998 WIDE Project; BSD-3,
> https://github.com/freebsd/freebsd-src).
>
> This product contains a derivation of Fabian Fett's 'Base64.swift' (Apache
> License 2.0, https://github.com/fabianfett/swift-base64-kit).
>
> This product contains a derivation of "XCTest+AsyncAwait.swift" &
> "StructuredConcurrencyHelpers" from AsyncHTTPClient (Apache License 2.0,
> https://github.com/swift-server/async-http-client).
>
> This product contains a derivation of "_TinyArray.swift" from
> SwiftCertificates (Apache License 2.0,
> https://github.com/apple/swift-certificates).
>
> This product contains a derivation of the mocking infrastructure from Swift
> System (Apache License 2.0, https://github.com/apple/swift-system).
>
> This product contains a derivation of "TokenBucket.swift" from Swift Package
> Manager (Apache License 2.0,
> https://github.com/swiftlang/swift-package-manager).

### SwiftCrypto

> The SwiftCrypto Project
>
> Please visit the SwiftCrypto web site for more information:
> https://github.com/apple/swift-crypto
>
> Copyright 2019 The SwiftCrypto Project
>
> The SwiftCrypto Project licenses this file to you under the Apache License,
> version 2.0 (the "License"); you may not use this file except in compliance
> with the License. You may obtain a copy of the License at:
> https://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations
> under the License.
>
> Also, please refer to each LICENSE.<component>.txt file, which is located in
> the 'license' directory of the distribution file, for the license terms of
> the components that this product depends on.
>
> This product contains test vectors from Google's wycheproof project (Apache
> License 2.0, https://github.com/google/wycheproof).
>
> This product contains a derivation of various files from SwiftNIO (Apache
> License 2.0, https://github.com/apple/swift-nio).

### SwiftASN1

> The SwiftASN1 Project
>
> Please visit the SwiftASN1 web site for more information:
> https://github.com/apple/swift-asn1
>
> Copyright 2022 The SwiftASN1 Project
>
> The SwiftASN1 Project licenses this file to you under the Apache License,
> version 2.0 (the "License"); you may not use this file except in compliance
> with the License. You may obtain a copy of the License at:
> https://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations
> under the License.
>
> Also, please refer to each LICENSE.txt file, which is located in the
> 'license' directory of the distribution file, for the license terms of the
> components that this product depends on.
>
> This product contains derivations of various scripts from SwiftNIO (Apache
> License 2.0, https://github.com/apple/swift-nio).
>
> This product contains derivations of various scripts from Swift OpenAPI
> Generator (Apache License 2.0,
> https://github.com/apple/swift-openapi-generator).

### Swift Markdown

> The Swift Markdown Project
>
> Please visit the Swift Markdown web site for more information:
> https://github.com/apple/swift-markdown
>
> Copyright (c) 2021 Apple Inc. and the Swift project authors
>
> The Swift Project licenses this file to you under the Apache License,
> version 2.0 (the "License"); you may not use this file except in compliance
> with the License. You may obtain a copy of the License at:
> https://www.apache.org/licenses/LICENSE-2.0
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations
> under the License.
>
> This product contains Swift Argument Parser (Apache License 2.0,
> https://github.com/apple/swift-argument-parser).
>
> This product contains a derivation of the cmark-gfm project (BSD-2,
> https://github.com/github/cmark-gfm).

## Trademarks and brand assets

The Claude icon (`TerminalRelay/Assets.xcassets/ClaudeIcon.imageset`) is a
trademark of Anthropic, PBC. The Codex icon
(`TerminalRelay/Assets.xcassets/CodexIcon.imageset`) is a trademark of OpenAI,
L.L.C. Terminal Relay uses these marks nominatively, solely to identify the
respective third-party services the app connects to. They are the property of
their respective owners, are NOT licensed under this repository's Apache
License 2.0, and no rights in them are granted by this repository. Do not
reuse them except as permitted by their owners' brand guidelines.

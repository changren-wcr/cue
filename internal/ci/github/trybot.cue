// Copyright 2022 The CUE Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package github

import (
	"list"

	"cuelang.org/go/internal/ci/core"

	"github.com/SchemaStore/schemastore/src/schemas/json"
)

// The trybot workflow.
trybot: _base.#bashWorkflow & {
	// Note: the name of this workflow is used by gerritstatusupdater as an
	// identifier in the status updates that are posted as reviews for this
	// workflows, but also as the result label key, e.g. "TryBot-Result" would
	// be the result label key for the "TryBot" workflow. Note the result label
	// key is therefore tied to the configuration of this repository.
	//
	// This name also shows up in the CI badge in the top-level README.
	name: "TryBot"

	on: {
		push: {
			branches: list.Concat([["trybot/*/*", _base.#testDefaultBranch], _#protectedBranchPatterns]) // do not run PR branches
			"tags-ignore": [core.#releaseTagPattern]
		}
		pull_request: {}
	}

	jobs: {
		test: {
			strategy:  _#testStrategy
			"runs-on": "${{ matrix.os }}"
			steps: [
				_base.#checkoutCode & {
					// "pull_request" builds will by default use a merge commit,
					// testing the PR's HEAD merged on top of the master branch.
					// For consistency with Gerrit, avoid that merge commit entirely.
					// This doesn't affect "push" builds, which never used merge commits.
					with: ref: "${{ github.event.pull_request.head.sha }}"
				},
				_base.#installGo,

				// cachePre must come after installing Node and Go, because the cache locations
				// are established by running each tool.
				for v in _#cachePre {v},

				_base.#earlyChecks & {
					// These checks don't vary based on the Go version or OS,
					// so we only need to run them on one of the matrix jobs.
					if: _#isLatestLinux
				},
				json.#step & {
					if:  _#isProtectedBranch
					run: "echo CUE_LONG=true >> $GITHUB_ENV"
				},
				_#goGenerate,
				_#goTest & {
					if: "\(_#isProtectedBranch) || !\(_#isLatestLinux)"
				},
				_#goTestRace & {
					if: _#isLatestLinux
				},
				_#goCheck,
				_base.#checkGitClean,
				_#pullThroughProxy,
				_#cachePost,
			]
		}
	}

	_#pullThroughProxy: json.#step & {
		name: "Pull this commit through the proxy on \(core.#defaultBranch)"
		run: """
			v=$(git rev-parse HEAD)
			cd $(mktemp -d)
			go mod init test

			# Try up to five times if we get a 410 error, which either the proxy or sumdb
			# can return if they haven't retrieved the requested version yet.
			for i in {1..5}; do
				# GitHub Actions defaults to "set -eo pipefail", so we use an if clause to
				# avoid stopping too early. We also use a "failed" file as "go get" runs
				# in a subshell via the pipe.
				rm -f failed
				if ! GOPROXY=https://proxy.golang.org go get cuelang.org/go@$v; then
					touch failed
				fi |& tee output.txt

				if [[ -f failed ]]; then
					if grep -q '410 Gone' output.txt; then
						echo "got a 410; retrying"
						sleep 1s # do not be too impatient
						continue
					fi
					exit 1 # some other failure; stop
				else
					exit 0 # success; stop
				fi
			done

			echo "giving up after a number of retries"
			exit 1
			"""
		if: "\(_#isProtectedBranch) && \(_#isLatestLinux)"
	}

	_#goGenerate: json.#step & {
		name: "Generate"
		run:  "go generate ./..."
		// The Go version corresponds to the precise version specified in
		// the matrix. Skip windows for now until we work out why re-gen is flaky
		if: _#isLatestLinux
	}

	_#goTest: json.#step & {
		name: "Test"
		run:  "go test ./..."
	}

	_#goCheck: json.#step & {
		// These checks can vary between platforms, as different code can be built
		// based on GOOS and GOARCH build tags.
		// However, CUE does not have any such build tags yet, and we don't use
		// dependencies that vary wildly between platforms.
		// For now, to save CI resources, just run the checks on one matrix job.
		// TODO: consider adding more checks as per https://github.com/golang/go/issues/42119.
		if:   "\(_#isLatestLinux)"
		name: "Check"
		run:  "go vet ./..."
	}

	_#goTestRace: json.#step & {
		name: "Test with -race"
		run:  "go test -race ./..."
	}
}

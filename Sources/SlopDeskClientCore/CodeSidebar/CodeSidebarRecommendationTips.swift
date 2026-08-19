// CodeSidebarRecommendationTips — the extension-recommendation catalogue the embedded workbench
// is missing, grafted into its boot configuration by the page-dressing script
// (`CodeSidebarPageDressing.recommendationTipsScript()`).
//
// WHY THE CLIENT CARRIES DATA THE SERVER SHOULD OWN: code-server's web client server hand-builds
// the `productConfiguration` it embeds in the workbench HTML and forwards only the extensions
// GALLERY from its product.json — none of the recommendation-tips keys ever reach the browser, so
// the Extensions view's RECOMMENDED section is permanently empty. Its product.json has no tips to
// forward anyway, and the only override seam (`product.overrides.json`) is compiled out of release
// builds. There is no supported server-side hook, so the client grafts the catalogue into the
// configuration meta tag before the workbench boots (2026-08-03).
//
// The catalogue is VS Code stable's own (product.json of 1.131.0, commit e4c7e7b1), narrowed to
// the keys this workbench actually consumes:
//
//   • `languageExtensionTips` — the ungated filler: populates RECOMMENDED immediately.
//   • `configBasedExtensionTips` — workspace config files (pom.xml, CMakeLists, …) → tips.
//   • `extensionRecommendations` — file-open driven (`onFileOpen` globs/languages).
//   • `keymapExtensionTips` — the `@recommended:keymaps` section.
//
// Deliberately EXCLUDED: `webExtensionTips` (consumed only when NO remote extension server exists
// — code-server always has one), `exeBasedExtensionTips` (scans local executables; desktop-only),
// `remoteExtensionTips`/`virtualWorkspaceExtensionTips` (remote-window and virtual-FS upsells —
// meaningless inside the panel). Every `important: true` is neutralized to `false`: stock VS Code
// uses the flag to raise install-prompt toasts on file open, and the panel recommends passively —
// section and badge, never a nag.
//
// Refresh (rarely needed — ids drift slowly) by re-extracting those four keys from a current
// VS Code stable product.json, re-applying the `important` neutralization, and replacing the
// literal; `CodeSidebarPageDressingTests` pin the shape.

package enum CodeSidebarRecommendationTips {
    // Generated data — upstream's own line lengths (glob/regex strings) ride verbatim.
    // swiftlint:disable line_length
    /// The catalogue as canonical JSON (2-space indent, sorted keys, ASCII-only) — parsed by the
    /// injected script via `JSON.parse`, pinned parseable by tests.
    package static let json = #"""
    {
      "configBasedExtensionTips": {
        ".flake8-linter": {
          "configName": "Python Linter",
          "configPath": ".flake8",
          "recommendations": {
            "ms-python.flake8": {
              "name": "Flake8"
            }
          }
        },
        ".pylintrc-linter": {
          "configName": "Python Linter",
          "configPath": ".pylintrc",
          "recommendations": {
            "ms-python.pylint": {
              "name": "Pylint"
            }
          }
        },
        "devContainer": {
          "configName": "Dev Container",
          "configPath": ".devcontainer/devcontainer.json",
          "recommendations": {
            "ms-vscode-remote.remote-containers": {
              "important": false,
              "name": "Dev Containers"
            }
          }
        },
        "git": {
          "configName": "Git",
          "configPath": ".git/config",
          "recommendations": {
            "eamodio.gitlens": {
              "name": "GitLens"
            },
            "github.vscode-pull-request-github": {
              "contentPattern": "^\\s*url\\s*=\\s*https:\\/\\/github\\.com.*$",
              "name": "GitHub Pull Request"
            }
          }
        },
        "github-pull-request": {
          "configName": "GitHub",
          "configPath": ".vscode/.github-pull-request.rec",
          "configScheme": "vscode-vfs",
          "recommendations": {
            "github.vscode-pull-request-github": {
              "important": false,
              "name": "GitHub Pull Request"
            }
          }
        },
        "gradle": {
          "configName": "Gradle",
          "configPath": "build.gradle",
          "recommendations": {
            "vscjava.vscode-java-pack": {
              "important": false,
              "isExtensionPack": true,
              "name": "Java",
              "whenNotInstalled": [
                "ASF.apache-netbeans-java",
                "Oracle.oracle-java"
              ]
            }
          }
        },
        "maven": {
          "configName": "Maven",
          "configPath": "pom.xml",
          "recommendations": {
            "vmware.vscode-boot-dev-pack": {
              "isExtensionPack": true,
              "name": "Spring Boot Extension Pack"
            },
            "vscjava.vscode-java-pack": {
              "important": false,
              "isExtensionPack": true,
              "name": "Java",
              "whenNotInstalled": [
                "ASF.apache-netbeans-java",
                "Oracle.oracle-java"
              ]
            }
          }
        },
        "mypy-ini-linter": {
          "configName": "Python Linter",
          "configPath": ".mypy.ini",
          "recommendations": {
            "ms-python.mypy-type-checker": {
              "name": "Mypy Type Checker"
            }
          }
        },
        "pep8-formatter": {
          "configName": "Python Formatter",
          "configPath": ".pep8",
          "recommendations": {
            "ms-python.autopep8": {
              "name": "Autopep8"
            }
          }
        },
        "pylintrc-linter": {
          "configName": "Python Linter",
          "configPath": "pylintrc",
          "recommendations": {
            "ms-python.pylint": {
              "name": "Pylint"
            }
          }
        },
        "pyproject-formatter": {
          "configName": "Python Formatter",
          "configPath": "pyproject.toml",
          "recommendations": {
            "ms-python.autopep8": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?autopep8\"?\\s*[\\].])|(\"autopep8\\s*[\"[(<=>!~;@])",
              "name": "Autopep8"
            },
            "ms-python.black-formatter": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?black\"?\\s*[\\].])|(\"black\\s*[\"[(<=>!~;@])",
              "name": "Black Formatter"
            }
          }
        },
        "pyproject-linter": {
          "configName": "Python Linter",
          "configPath": "pyproject.toml",
          "recommendations": {
            "charliermarsh.ruff": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?ruff\"?\\s*[\\].])|(\"ruff\\s*[\"[(<=>!~;@])",
              "name": "Ruff"
            },
            "ms-python.flake8": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?flake8\"?\\s*[\\].])|(\"flake8\\s*[\"[(<=>!~;@])",
              "name": "Flake8"
            },
            "ms-python.mypy-type-checker": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?mypy\"?\\s*[\\].])|(\"mypy\\s*[\"[(<=>!~;@])",
              "name": "Mypy Type Checker"
            },
            "ms-python.pylint": {
              "contentPattern": "(^\\s*\\[\\[?\\s*\"?tool\"?\\s*\\.\\s*\"?pylint\"?\\s*[\\].])|(\"pylint\\s*[\"[(<=>!~;@])",
              "name": "Pylint"
            }
          }
        },
        "python-setup-cgf-formatter": {
          "configName": "Python Formatter",
          "configPath": "setup.cfg",
          "recommendations": {
            "ms-python.autopep8": {
              "contentPattern": "^\\[pep8\\]",
              "name": "Autopep8"
            }
          }
        },
        "python-setup-cgf-linter": {
          "configName": "Python Linter",
          "configPath": "setup.cfg",
          "recommendations": {
            "ms-python.flake8": {
              "contentPattern": "^\\[flake8\\]",
              "name": "Flake8"
            }
          }
        },
        "tox-ini-formatter": {
          "configName": "Python Formatter",
          "configPath": "tox.ini",
          "recommendations": {
            "ms-python.autopep8": {
              "contentPattern": "^\\[pep8\\]",
              "name": "Autopep8"
            }
          }
        },
        "tox-ini-linter": {
          "configName": "Python Linter",
          "configPath": "tox.ini",
          "recommendations": {
            "ms-python.flake8": {
              "contentPattern": "^\\[flake8\\]",
              "name": "Flake8"
            }
          }
        }
      },
      "extensionRecommendations": {
        "Angular.ng-template": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.angular-cli.json,**/angular.json,**/*.ng.html,**/*.ng,**/*.ngml}"
            }
          ]
        },
        "DavidAnson.vscode-markdownlint": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.md}"
            }
          ]
        },
        "DotJoshJohnson.xml": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.xml}"
            }
          ]
        },
        "EditorConfig.EditorConfig": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.editorconfig}"
            }
          ]
        },
        "GitHub.copilot": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.ts,**/*.tsx,**/*.js,**/*.jsx,**/*.py,**/*.go,**/*.rb,**/*.html,**/*.css,**/*.php,**/*.cpp,**/*.vue,**/*.c,**/*.sql,**/*.java,**/*.cs,**/*.rs,**/*.dart,**/*.ps,**/*.ps1,**/*.tex}"
            }
          ]
        },
        "GitHub.copilot-chat": {
          "onSettingsEditorOpen": {
            "descriptionOverride": "GitHub Copilot is an AI-powered coding assistant that helps you write code faster and smarter."
          }
        },
        "GitHub.vscode-github-actions": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/.github/workflows/*.yml}"
            }
          ]
        },
        "HashiCorp.terraform": {
          "onFileOpen": [
            {
              "pathGlob": "**/*.tf"
            }
          ]
        },
        "HookyQR.beautify": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.jsbeautifyrc}"
            }
          ]
        },
        "Ionide.Ionide-fsharp": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.fsx,**/*.fsi,**/*.fs,**/*.ml,**/*.mli}"
            }
          ]
        },
        "Oracle.oracledevtools": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.sql}"
            }
          ]
        },
        "REditorSupport.r": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.r}"
            },
            {
              "important": false,
              "languages": [
                "r"
              ]
            }
          ]
        },
        "Redis.redis-for-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/redis.*,**/redis-server.*,**/redis_*,**/redisinsight.*}"
            }
          ]
        },
        "Shopify.ruby-lsp": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.rb,**/*.erb,**/*.reek,**/.fasterer.yml,**/ruby-lint.yml,**/.rubocop.yml}"
            }
          ]
        },
        "SonarSource.sonarlint-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/sonar-project.properties,**/sonarcloud.properties,**/sonarlint.*}"
            }
          ]
        },
        "betterthantomorrow.calva": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.clj,**/*.cljs}"
            }
          ]
        },
        "bmewburn.vscode-intelephense-client": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.php,**/php.ini}"
            }
          ]
        },
        "cake-build.cake-vscode": {
          "onFileOpen": [
            {
              "pathGlob": "{**/build.cake}"
            }
          ]
        },
        "christian-kohler.npm-intellisense": {
          "onFileOpen": [
            {
              "pathGlob": "{**/package.json}"
            }
          ]
        },
        "circleci.circleci": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.circleci/config.yml}"
            }
          ]
        },
        "dbaeumer.vscode-eslint": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.js,**/*.jsx,**/*.es6,**/.eslintrc.*,**/.eslintrc,**/.babelrc,**/jsconfig.json}"
            }
          ]
        },
        "donjayamanne.githistory": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.gitignore,**/.git}"
            }
          ]
        },
        "eamodio.gitlens": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.gitignore,**/.git}"
            }
          ]
        },
        "firefox-devtools.vscode-firefox-debug": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.ts,**/*.tsx,**/*.js,**/*.jsx,**/*.es6,**/.babelrc}"
            }
          ]
        },
        "golang.Go": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "**/*.go"
            },
            {
              "important": false,
              "languages": [
                "go"
              ]
            }
          ]
        },
        "k--kato.intellij-idea-keybindings": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.idea}"
            }
          ]
        },
        "mechatroner.rainbow-csv": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "**/*.csv"
            }
          ]
        },
        "microsoft-aspire.aspire-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/apphost.cs,**/apphost.js,**/apphost.ts,**/apphost.py,**/AppHost.java,**/aspire.config.json,**/.aspire/settings.json}"
            }
          ]
        },
        "ms-azure-devops.azure-pipelines": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/azure-pipelines.yaml}"
            }
          ]
        },
        "ms-azuretools.vscode-azureterraform": {
          "onFileOpen": [
            {
              "pathGlob": "**/*.tf"
            }
          ]
        },
        "ms-azuretools.vscode-bicep": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.bicep}",
              "whenNotInstalled": [
                "ms-azuretools.rad-vscode-bicep"
              ]
            }
          ]
        },
        "ms-azuretools.vscode-containers": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/dockerfile,**/Dockerfile,**/docker-compose.yml,**/docker-compose.*.yml}",
              "whenNotInstalled": [
                "ms-azuretools.vscode-docker"
              ]
            },
            {
              "important": false,
              "languages": [
                "dockerfile"
              ],
              "whenNotInstalled": [
                "ms-azuretools.vscode-docker"
              ]
            },
            {
              "pathGlob": "{**/*.cs,**/project.json,**/global.json,**/*.csproj,**/*.cshtml,**/*.sln,**/appsettings.json,**/*.py,**/*.ipynb,**/*.js,**/*.ts,**/package.json}",
              "whenNotInstalled": [
                "ms-azuretools.vscode-docker"
              ]
            }
          ]
        },
        "ms-dotnettools.csdevkit": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.cs,**/global.json,**/*.csproj,**/*.cshtml,**/*.sln}"
            },
            {
              "important": false,
              "languages": [
                "csharp"
              ]
            },
            {
              "pathGlob": "{**/project.json,**/appsettings.json}"
            }
          ]
        },
        "ms-edgedevtools.vscode-edge-devtools": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.ts,**/*.tsx,**/*.js,**/*.css,**/*.html}"
            }
          ]
        },
        "ms-kubernetes-tools.vscode-kubernetes-tools": {
          "onFileOpen": [
            {
              "pathGlob": "{**/Chart.yaml}"
            }
          ]
        },
        "ms-mssql.mssql": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.sql}"
            }
          ]
        },
        "ms-playwright.playwright": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*playwright*.config.ts,**/*playwright*.config.js,**/*playwright*.config.mjs}"
            }
          ]
        },
        "ms-python.python": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.py}"
            },
            {
              "important": false,
              "languages": [
                "python"
              ]
            },
            {
              "pathGlob": "{**/*.ipynb}"
            }
          ]
        },
        "ms-toolsai.datawrangler": {
          "onFileOpen": [
            {
              "contentPattern": "import\\s*pandas|from\\s*pandas",
              "pathGlob": "{**/*.ipynb}",
              "whenInstalled": [
                "ms-toolsai.jupyter"
              ]
            }
          ]
        },
        "ms-toolsai.jupyter": {
          "onFileOpen": [
            {
              "contentPattern": "^#\\s*%%$",
              "important": false,
              "pathGlob": "{**/*.py}",
              "whenInstalled": [
                "ms-python.python"
              ]
            },
            {
              "pathGlob": "{**/*.ipynb}"
            }
          ]
        },
        "ms-toolsai.prompty": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.prompty}"
            }
          ]
        },
        "ms-vscode-remote.remote-containers": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/devcontainer.json}"
            }
          ]
        },
        "ms-vscode.PowerShell": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.ps1,**/*.psd1,**/*.psm1}"
            },
            {
              "important": false,
              "languages": [
                "powershell"
              ]
            },
            {
              "pathGlob": "{**/*.ps.config,**/*.ps1.config}"
            }
          ]
        },
        "ms-vscode.cmake-tools": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/CMakeLists.txt}"
            }
          ]
        },
        "ms-vscode.cpptools-extension-pack": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.c,**/*.cpp,**/*.cc,**/.cxx,**/*.hh,**/*.hpp,**/*.hxx,**/*.h}",
              "whenNotInstalled": [
                "llvm-vs-code-extensions.vscode-clangd"
              ]
            },
            {
              "important": false,
              "languages": [
                "c",
                "cpp"
              ],
              "whenNotInstalled": [
                "llvm-vs-code-extensions.vscode-clangd"
              ]
            }
          ]
        },
        "ms-vscode.makefile-tools": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/makefile,**/Makefile}"
            },
            {
              "important": false,
              "languages": [
                "makefile"
              ]
            }
          ]
        },
        "ms-vscode.sublime-keybindings": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.sublime-project,**/.sublime-workspace}"
            }
          ]
        },
        "ms-vscode.vscode-chat-customizations-evaluations": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*prompt.md, **/*skill.md, **/*instructions.md, **/*agent.md}"
            },
            {
              "important": false,
              "languages": [
                "prompt",
                "chatagent",
                "skill",
                "instructions"
              ]
            }
          ]
        },
        "ms-vscode.vscode-github-issue-notebooks": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.github-issues}"
            }
          ]
        },
        "msazurermtools.azurerm-vscode-tools": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/azuredeploy.json}"
            }
          ]
        },
        "mtxr.sqltools": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.sql}"
            }
          ]
        },
        "quantum.qsharp-lang-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.qs,**/*.qsc,**/*.qasm}"
            }
          ]
        },
        "rust-lang.rust-analyzer": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.rs,**/*.rslib}"
            }
          ]
        },
        "stylelint.vscode-stylelint": {
          "onFileOpen": [
            {
              "pathGlob": "{**/.stylelintrc,**/stylelint.config.js}"
            }
          ]
        },
        "svelte.svelte-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.svelte}"
            }
          ]
        },
        "swiftlang.swift-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.swift,**/*.swiftinterface}"
            }
          ]
        },
        "tomoki1207.pdf": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "**/*.pdf"
            }
          ]
        },
        "typespec.typespec-vscode": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.tsp,**/tspconfig.yaml}"
            }
          ]
        },
        "usqlextpublisher.usql-vscode-ext": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.usql}"
            }
          ]
        },
        "vmware.vscode-boot-dev-pack": {
          "onFileOpen": [
            {
              "pathGlob": "{**/application.properties}"
            }
          ]
        },
        "vsciot-vscode.vscode-arduino": {
          "onFileOpen": [
            {
              "pathGlob": "**/*.ino"
            }
          ]
        },
        "vscjava.vscode-gradle": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/gradlew,**/gradlew.bat,**/build.gradle,**/build.gradle.kts,**/settings.gradle,**/settings.gradle.kts}"
            }
          ]
        },
        "vscjava.vscode-java-pack": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.java}",
              "whenNotInstalled": [
                "ASF.apache-netbeans-java",
                "Oracle.oracle-java"
              ]
            },
            {
              "important": false,
              "languages": [
                "java"
              ],
              "whenNotInstalled": [
                "ASF.apache-netbeans-java",
                "Oracle.oracle-java"
              ]
            }
          ]
        },
        "vscjava.vscode-maven": {
          "onFileOpen": [
            {
              "pathGlob": "**/pom.xml"
            }
          ]
        },
        "vue.volar": {
          "onFileOpen": [
            {
              "important": false,
              "pathGlob": "{**/*.vue}"
            },
            {
              "important": false,
              "languages": [
                "vue"
              ]
            }
          ]
        },
        "xdebug.php-debug": {
          "onFileOpen": [
            {
              "pathGlob": "{**/*.php,**/php.ini}"
            }
          ]
        }
      },
      "keymapExtensionTips": [
        "vscodevim.vim",
        "ms-vscode.sublime-keybindings",
        "ms-vscode.atom-keybindings",
        "ms-vscode.brackets-keybindings",
        "ms-vscode.vs-keybindings",
        "ms-vscode.notepadplusplus-keybindings",
        "k--kato.intellij-idea-keybindings",
        "lfs.vscode-emacs-friendly",
        "alphabotsec.vscode-eclipse-keybindings",
        "alefragnani.delphi-keybindings"
      ],
      "languageExtensionTips": [
        "ms-python.python",
        "ms-vscode.cpptools-extension-pack",
        "ms-dotnettools.csdevkit",
        "ms-toolsai.jupyter",
        "vscjava.vscode-java-pack",
        "ecmel.vscode-html-css",
        "vue.volar",
        "bmewburn.vscode-intelephense-client",
        "dsznajder.es7-react-js-snippets",
        "golang.go",
        "ms-vscode.powershell",
        "dart-code.dart-code",
        "rust-lang.rust-analyzer",
        "Shopify.ruby-lsp",
        "GitHub.copilot"
      ]
    }
    """#
    // swiftlint:enable line_length
}

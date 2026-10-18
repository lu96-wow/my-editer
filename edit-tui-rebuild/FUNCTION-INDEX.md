# Function Index

> 自动生成：`edit-tui-rebuild` 下除 `test/`、`demo/`、`compiled/` 外的所有**顶层** `struct` / `define` / `define-syntax`。
> 行号只用于导航；`struct` 行不展开自动生成的构造器 / 谓词 / 访问器。

## `base/effect.rkt`

**structs**: `edit-effect`:69, `insert-text-effect`:70, `set-text-effect`:71, `set-input-prompt-effect`:72, `set-face-layer-effect`:79, `replace-range-effect`:81, `ensure-view-effect`:83, `submit-service-effect`:90, `select-effect`:91, `scroll-effect`:92, `nav-effect`:93, `undo-effect`:94, `redo-effect`:95, `open-doc-effect`:96, `open-view-effect`:97, `close-view-effect`:98, `close-doc-effect`:99, `save-doc-effect`:100, `read-file-effect`:101, `write-file-effect`:102, `make-directory-effect`:103, `delete-file-effect`:104, `spawn-effect`:105, `timer-effect`:106, `emit-effect`:107, `quit-effect`:108

**definitions**: `effect?`:110, `effect-kind`:123

## `base/event.rkt`

**structs**: `key-event`:30, `mouse-event`:31, `resize-event`:32, `paste-event`:33, `internal-event`:34, `tick-event`:35, `quit-event`:36

**definitions**: `event?`:38, `event-kind`:42

## `base/face.rkt`

**structs**: `face`:30

**definitions**: `face-empty`:35, `face-set-fg`:39, `face-set-bg`:42, `face-set-attrs`:45, `face-add-attr`:49, `face-remove-attr`:55, `face-has-attr?`:60

## `base/id.rkt`

**structs**: `id`:27, `id-counter`:48

**definitions**: `doc-id?`:29, `view-id?`:30, `region-id?`:31, `job-id?`:32, `id->string`:34, `id=?`:38, `doc-id`:41, `view-id`:42, `region-id`:43, `job-id`:44, `make-id-counter`:51, `id-counter-next`:55, `next-id`:69

## `base/keymap.rkt`

**structs**: `binding`:39, `keymap`:42

**definitions**: `empty-keymap`:45, `keymap-add`:48, `keymap-step`:61, `keymap-ref`:65, `keymap-navigate`:72, `keymap-prefix?`:80, `keymap-lookup`:83, `keys`:97, `keymap-from-bindings`:102

## `base/signal.rkt`

**structs**: `signal`:47, `signals`:56

**definitions**: `standard-signal-points`:34, `known-signal-point?`:45, `make-signal`:51, `signals-empty`:58, `signals-add`:61, `signals-take`:64

## `base/status-part.rkt`

**structs**: `status-part`:14

**definitions**: `make-status-part`:18

## `base/transition.rkt`

**structs**: `transition`:30

**definitions**: `transition-pure`:34, `transition-with-effects`:36, `transition-bind`:43, `transition-all`:49, `transition-map-state`:56, `transition-map-effects`:59

## `bootstrap/commands/document.rkt`

**definitions**: `mount-opened-document`:55, `open-file-from-path`:62, `open-file-prompt-command`:86, `close-doc-action*`:90, `doc-dirty?`:95, `saveable-doc?`:102, `dirty-docs`:105, `doc-label`:111, `save-confirm-label`:115, `close-doc-action`:118, `confirm-current-doc`:139, `save-confirm-show`:147, `save-confirm-show-state`:150, `save-confirm-start`:153, `confirm-next`:163, `confirm-finish`:177, `confirm-save-current`:187, `save-docs-then`:210, `input-submit-command`:242, `input-cancel-command`:258, `handle-save-answer`:262, `save-doc-to-path`:283, `save-current-command`:306, `default-input-commands`:329, `request-quit-command`:353, `request-close-doc`:362, `request-close-file-command`:371, `close-file-command`:380

## `bootstrap/commands/edit.rkt`

**definitions**: `nav-command`:26, `insert-command`:33, `edit-command`:40, `undo-command`:47, `redo-command`:53, `quit-command`:59

## `bootstrap/commands/focus.rkt`

**definitions**: `focus-move-command`:35, `focus-move`:38, `screen->point`:62, `pointer-press-command`:87, `pointer-drag-command`:109

## `bootstrap/commands/placement.rkt`

**definitions**: `place-cancel-command`:34, `place-into`:48, `place-commit-command`:94, `place-at-command`:97, `placement-scope`:100, `placement-keys`:103

## `bootstrap/commands/region.rkt`

**definitions**: `subject-region`:28, `count-role-regions`:36, `last-region-of-role?`:42, `drop-region-views`:46, `fallback-view`:53, `close-region-command`:59, `close-region`:62

## `bootstrap/commands/table.rkt`

**definitions**: `default-command-table`:21

## `bootstrap/commands/util.rkt`

**definitions**: `message`:37, `view-subject`:41, `region-subject`:47, `input-busy?`:55, `frame-area`:57, `notice-state-value`:60, `notice-state`:63, `real-view?`:68, `fallback-attached-view`:72

## `bootstrap/commands/view.rkt`

**definitions**: `split-region-command`:44, `split-region`:54, `axis/side`:69, `mount-split`:77, `close-view-command`:99, `close-view`:102, `region-has-view?`:129, `target-region-for-new-view*`:134, `target-region-for-new-view`:145, `mount-view-in-region`:148, `new-document-command`:156, `detach-view-command`:174, `attach-detached-command`:191, `switch-member-command`:223

## `bootstrap/defaults.rkt`

**definitions**: `text-keys`:39, `pointer-keys`:53, `nav-keys`:59, `input-keys`:69, `core-global-keys`:81, `core-env`:107

## `bootstrap/panel.rkt`

**definitions**: `panel-spec-install!`:20

## `chrome/input.rkt`

**definitions**: `input-active?`:39, `input-value`:42, `input-cancel`:58, `input-show`:69, `input-show-state`:76

## `chrome/slot.rkt`

**definitions**: `install-chrome!`:33, `chrome-slot*`:51, `chrome-status-view`:54, `chrome-input-view`:58, `chrome-show-view`:62, `chrome-show-input`:75, `chrome-show-status`:79, `input-view`:91, `input-show`:94, `input-finish`:103, `input-read-text`:111, `input-write-prompt`:116, `sync-chrome!`:126

## `command/command.rkt`

**structs**: `command`:39, `input`:44

**definitions**: `input-kinds`:46, `cmd`:49, `->command`:57, `command-note-string`:63, `command-needs-input?`:69

## `command/key.rkt`

**structs**: `key-token`:27

**definitions**: `mods-order`:25, `normalize-mods`:29, `char->key-name`:32, `->key-name`:37, `key`:43, `key?`:46, `key-name`:47, `key-mods`:48, `key->string`:51

## `command/keymap.rkt`

**structs**: `keymap`:68, `keytable`:126, `matcher`:163

**definitions**: `empty-keymap`:71, `keymap-set`:74, `keymap-lookup`:89, `keymap-ref`:93, `keymap-navigate`:100, `keymap-prefix?`:108, `keymap-conflict-seq`:112, `make-keytable`:130, `keytable-merge!`:134, `keytable-lookup`:152, `make-matcher`:167, `matcher-feed!`:173, `matcher-reset!`:181, `matcher-pending`:184, `keytable-hints`:190, `keytable-commands`:205, `keys`:222, `keymap-from-bindings`:227

## `command/mouse.rkt`

**structs**: `mouse-token`:27

**definitions**: `mouse-actions`:23, `mouse-buttons`:25, `mouse`:29, `mouse?`:40, `mouse-action`:41, `mouse-button`:42, `mouse-mods`:43, `mouse->string`:45

## `command/tui.rkt`

**structs**: `key-reader`:65

**definitions**: `mods-order`:36, `mods->symbols`:38, `event->key`:46, `event->mouse`:50, `mouse-position`:57, `make-key-reader`:68, `key-reader-reset!`:70, `key-reader-pending`:73, `key-reader-pending-string`:76, `key-reader-table`:80, `key-reader-feed!`:88

## `core-render/render.rkt`

**definitions**: `fragment`:28, `render-piece`:32, `render-pieces`:39, `attr-fragment`:43, `face-fragment`:52, `style-fragment`:63, `render-clear`:68

## `dispatch/context.rkt`

**structs**: `ctx`:30

**definitions**: `make-ctx`:32

## `dispatch/hooks.rkt`

**definitions**: `max-rounds`:38, `run-hooks`:41, `point-hooks`:57, `run-point`:63

## `dispatch/pipeline.rkt`

**definitions**: `dispatch`:48, `message-expiring-event?`:87, `dispatch-key`:95, `dispatch-key-normal`:113, `dispatch-mouse`:128, `dispatch-mouse*`:133, `dispatch-resize`:193, `dispatch-paste`:198, `run-command`:205, `dispatch-unbound`:228, `sequence->string`:242, `token-text`:246, `focusable-subject?`:259, `notice`:267

## `dispatch/rules.rkt`

**definitions**: `subject-doc-meta`:37, `subject-mode-id`:42, `input-mode-rules`:48, `doc-layer-rules`:52, `mode-rules`:57, `global-rules`:64, `extra-rules`:68, `rules-for`:75, `prefix-rules`:88, `lookup-rules`:95

## `effects/engine.rkt`

**structs**: `engine`:66, `engine-view`:343, `open-doc-spec`:415

**definitions**: `make-engine`:73, `engine-set-face-layers!`:79, `engine-set-face-layer!`:84, `engine-attach-decors!`:91, `engine-decors-attached?`:101, `engine-paint-advance!`:105, `reset-paint-for-buffer!`:113, `engine-doc-buffer`:123, `engine-view-object`:126, `engine-doc-exists?`:129, `engine-view-exists?`:130, `engine-add-doc!`:132, `engine-add-view!`:136, `engine-create-doc!`:143, `engine-create-view!`:148, `engine-sync-view!`:160, `engine-ensure-view!`:173, `engine-sync-views!`:179, `engine-set-view-text!`:189, `engine-remove-view!`:205, `engine-remove-doc!`:213, `engine-effect?`:228, `engine-apply!`:237, `engine-replace-range!`:294, `engine-undo-redo!`:301, `whole-range`:313, `whole-change`:321, `need-view`:324, `apply-nav!`:328, `make-engine-view`:345, `ev-buffer`:347, `ev-view`:350, `engine-view-doc-text`:353, `engine-view-doc-name`:357, `engine-view-view-text`:361, `engine-view-view-readonly-at?`:365, `engine-view-doc-version`:371, `engine-version=?`:375, `engine-view-view-point`:377, `engine-view-view-point-line`:381, `engine-view-view-point-column`:385, `engine-view-view-selections`:389, `engine-view-view-cursor-position`:393, `engine-view-view-screen-position->point`:397, `engine-view-view-width`:401, `engine-view-view-height`:405, `engine-view-view-line-numbers?`:409, `make-open-doc-spec`:417, `open-doc-effect*`:425

## `effects/interpreter.rkt`

**definitions**: `runtime-effect?`:43, `interpret-effect!`:49, `interpret-replace-range!`:143, `edit-write?`:158, `effect-doc`:164, `interpret-open-doc!`:176, `interpret-open-view!`:202, `interpret-save-doc!`:216, `interpret-effects!`:250, `interpret-effect-tree!`:256

## `effects/paint.rkt`

**structs**: `paint-state`:49

**definitions**: `paint-state-of`:59, `set-paint-state!`:62, `paint-open!`:69, `paint-reset!`:83, `paint-fork`:88, `paint-advance!`:128, `paint-set-static-layer!`:152, `fills->layer-track`:165, `paint-write!`:185

## `effects/panel.rkt`

**definitions**: `panel-create-view!`:58, `panel-region-add!`:77, `panel-region-install!`:100, `panel-install!`:114, `panel-visible?`:125, `panel-uninstall!`:142, `panel-sync-buffer!`:175

## `env/command.rkt`

**definitions**: `command-run/ctx`:43, `command-note-text`:47

## `env/defaults.rkt`

**definitions**: `default-roles`:18, `default-modes`:29, `default-environment`:34

## `env/doc-type.rkt`

**structs**: `doc-type`:26

**definitions**: `make-doc-type`:32, `path-extension`:46, `doc-type-matches-path?`:50

## `env/environment.rkt`

**structs**: `environment`:73

**definitions**: `environment-empty`:89, `make-environment`:92, `environment-role`:110, `environment-mode`:113, `environment-command`:116, `environment-keymap`:119, `environment-doc-type`:122, `environment-doc-type-for-path`:125, `environment-mode-keymaps`:131, `environment-add-role`:136, `environment-add-mode`:140, `environment-add-scope`:144, `environment-add-command`:148, `environment-add-keymap`:153, `environment-add-rule`:159, `environment-add-status-part`:162, `environment-add-status-parts`:166, `environment-add-doc-type`:172, `environment-add-input-command`:176, `environment-add-panel-sync`:180, `environment-add-panel-syncs`:185, `environment-add-hook`:189, `environment-add-hooks`:193, `environment-add-face-layer`:197, `environment-add-face-layers`:201, `environment-add-decor`:205, `environment-add-decors`:209, `environment-merge`:213

## `env/hook.rkt`

**structs**: `hook`:29

**definitions**: `make-hook`:35

## `env/input-command.rkt`

**structs**: `input-command`:22

**definitions**: `make-input-command`:28, `input-command-prefix`:32, `input-command-regexp`:40, `input-command-list`:45

## `env/mode.rkt`

**structs**: `mode`:22

**definitions**: `make-mode`:26, `mode-default`:34

## `env/plugin.rkt`

**structs**: `panel-spec`:60, `plugin`:79

**definitions**: `make-panel-spec`:66, `make-plugin`:81, `plugin-env-apply`:103, `plugins-env`:115, `plugins-apply`:120

## `env/role.rkt`

**structs**: `role`:23

**definitions**: `make-role`:30, `role-default`:39

## `env/rule.rkt`

**structs**: `rule`:19

**definitions**: `make-rule`:23

## `env/scope.rkt`

**structs**: `scope`:26

**definitions**: `make-scope`:29, `scope-known?`:34, `scope-ok?`:37

## `model/chrome.rkt`

**structs**: `chrome-slot`:22, `chrome`:27

**definitions**: `make-chrome-slot`:24, `chrome-empty`:32, `make-chrome`:34, `chrome-set-message`:37, `chrome-clear-message`:38, `chrome-log-append`:39, `chrome-set-slot`:41

## `model/face-decor.rkt`

**structs**: `face-decor`:72, `face-ctx`:79, `dirty`:89

**definitions**: `dirty-all`:91, `dirty-lines`:92, `dirty-empty?`:93, `dirty-union`:95, `dirty->lines`:101, `change-line-span`:108, `changes->dirty-lines`:112, `scan-track`:121, `blank-layer-track`:127, `refresh-layer`:137, `change-spans`:167, `stateful-advance`:182, `face-runs`:228

## `model/face-layer.rkt`

**definitions**: `compose-face`:42, `compose-layers`:60

## `model/input.rkt`

**structs**: `gesture`:21, `input`:29

**definitions**: `idle-gesture?`:26, `make-gesture`:27, `input-empty`:34, `make-input`:36, `input-pending?`:41, `input-clear-pending`:42, `input-set-pending`:43, `input-push-mode`:44, `input-pop-mode`:45, `input-set-gesture`:48

## `model/layout.rkt`

**structs**: `dim`:39, `leaf`:51, `split`:52

**definitions**: `fixed`:43, `flex`:44, `->dim`:45, `dim-fixed?`:46, `dim-flex?`:47, `leaf-borders-all`:54, `leaf-borders-none`:55, `node?`:57, `node-dim`:58, `node-visible?`:59, `node-with-dim`:62, `make-leaf`:66, `make-split`:71, `empty-tree`:76, `empty-tree?`:77, `tree-find`:81, `tree-contains?`:85, `tree-leaves`:87, `tree-regions`:91, `tree-visible-leaves`:93, `tree-visible-regions`:98, `tree-visible?`:100, `map-leaves`:106, `tree-set-dim`:113, `tree-set-visible`:117, `tree-set-borders`:121, `tree-show`:125, `tree-hide`:126, `tree-insert`:138, `tree-split`:173, `tree-detach`:186, `tree-close`:201, `tree-move`:205

## `model/save.rkt`

**structs**: `save-confirm`:21

**definitions**: `make-save-confirm`:23

## `model/state.rkt`

**structs**: `window`:50, `runtime`:57, `state`:67

**definitions**: `make-window`:53, `make-runtime`:62, `make-state`:69, `state-empty`:80, `state-set-window`:84, `state-set-workspace`:85, `state-set-input`:86, `state-set-chrome`:87, `state-set-runtime`:88, `state-set-ids`:89, `state-set-confirm`:90, `state-set-store`:91, `state-set-signals`:92, `state-workspace*`:95, `state-input*`:96, `state-chrome*`:97, `state-runtime*`:98, `state-confirm*`:99, `state-store*`:100, `state-emit`:105, `state-drain-signals`:109, `plugin-state`:117, `plugin-state-set`:119, `plugin-state*`:121, `state-mark-quit`:124, `state-bump-revision`:126, `state-next-id`:130, `state-focus`:136, `state-input-active?`:139, `state-set-focus`:146

## `model/workspace.rkt`

**structs**: `doc-meta`:63, `view-meta`:82, `region-member`:88, `region`:97, `float`:108, `workspace`:116

**definitions**: `make-doc-meta`:74, `view-member`:95, `view-region-member?`:96, `workspace-empty`:131, `make-workspace`:135, `workspace-set-root`:146, `workspace-set-placement`:149, `workspace-float`:154, `workspace-add-float`:159, `drop-floats`:166, `workspace-remove-float`:169, `workspace-doc`:177, `workspace-view`:178, `workspace-region`:179, `workspace-doc-of-view`:181, `workspace-view-region`:185, `workspace-region-members`:191, `workspace-region-active`:195, `workspace-region-views`:199, `workspace-add-doc`:206, `workspace-add-view`:209, `workspace-add-region`:212, `remove-view-from-regions`:218, `workspace-detach-view`:234, `workspace-attach-view`:238, `workspace-view-attached?`:256, `workspace-detached-views`:259, `workspace-remove-view`:270, `workspace-remove-region`:295, `workspace-remove-doc`:302, `workspace-focus-view`:313, `workspace-set-focus`:316, `workspace-set-focus*`:325, `workspace-pop-focus`:331

## `plugins/builtin.rkt`

**definitions**: `default-plugins`:33, `default-env`:37, `editor-plugins`:42, `editor-env`:54

## `plugins/completion/plugin.rkt`

**definitions**: `session-key`:58, `popup-view-key`:59, `popup-region-key`:60, `cache-key`:61, `jobs-key`:62, `popup-id`:64, `completion-mode-name`:65, `completion-session`:67, `set-session`:68, `completion-popup-view`:70, `popup-region`:71, `popup-float`:72, `install-completion-popup!`:78, `completion-open?`:89, `line-at`:93, `prefix-at`:99, `doc-words`:108, `open-doc-ids`:115, `local-words`:120, `base-pool`:126, `module-path-context?`:138, `filter-pool`:150, `rank-candidates`:157, `cache-of`:166, `cache-get`:168, `cache-put`:170, `pending?`:174, `pending-add`:176, `pending-del`:180, `jobs-of`:185, `job-add`:186, `job-take`:188, `submit-job`:193, `popup-window`:200, `session-candidates`:204, `session-index`:205, `session-name`:206, `session-binding`:210, `selection-state`:217, `popup-content`:223, `popup-doc`:240, `render-popup`:245, `open-popup`:264, `close-popup`:276, `msg`:289, `open-with-pool`:292, `maybe-open-cached`:304, `completion-open`:335, `completion-move`:377, `completion-refine-hook`:387, `completion-accept`:412, `completion-cancel`:436, `completion-noop`:439, `completion-on-job`:443, `completion-keys`:462, `completion-popup-keys`:466, `completion-doc-keys`:476, `completion-plugin`:482

## `plugins/docs/plugin.rkt`

**definitions**: `panel-key`:51, `state-key`:52, `cache-key`:53, `jobs-key`:54, `docs-panel-view`:58, `docs-panel-spec`:60, `install-docs-panel!`:66, `docs-keys`:70, `docs-state`:80, `set-docs-state`:81, `cache-of`:83, `cache-get`:85, `cache-has?`:86, `cache-put`:87, `pending?`:91, `pending-add`:93, `pending-del`:97, `jobs-of`:102, `job-add`:103, `job-take`:105, `ident-char?`:112, `line-at`:116, `identifier-at`:122, `builtin-docs`:134, `doc-context`:162, `online-docs`:185, `origin-text`:188, `docs-lines`:196, `docs-text`:207, `docs-fills`:212, `docs-region`:223, `docs-open?`:227, `hide-docs`:231, `show-docs`:240, `docs-panel-doc`:250, `write-docs`:254, `submit-doc-job`:266, `docs-show-impl`:273, `docs-show-command`:316, `docs-toggle-command`:320, `docs-on-nav`:328, `docs-on-selection`:338, `docs-on-job`:346, `docs-keys-table`:376, `docs-plugin`:380

## `plugins/filetree/commands.rkt`

**definitions**: `message`:45, `notice-state`:49, `selected-line`:53, `selected-dir`:58, `doc-views`:67, `find-doc-by-path`:73, `ensure-editor-region`:81, `attach-and-focus`:105, `begin-open-placement`:114, `open-file-placement`:123, `filetree-min-size`:170, `toggle-filetree-command`:172, `filetree-enter-command`:220, `resolve-path`:237, `create-file-prompt-command`:241, `create-folder-prompt-command`:248, `delete-file-command`:255, `create-file-handler`:266, `delete-file-handler`:287, `create-folder-handler`:306, `filetree-input-commands`:327, `filetree-keys`:342, `nav-command`:355, `filetree-command-table`:362

## `plugins/filetree/lines.rkt`

**structs**: `filetree-line`:32

**definitions**: `open-doc-paths`:39, `indent`:44, `entry-name`:46, `filetree-lines`:49, `filetree-line-at`:80, `filetree-dir?`:86, `filetree-file?`:87

## `plugins/filetree/model.rkt`

**structs**: `filetree`:26

**definitions**: `empty-filetree`:28, `make-filetree`:30, `filetree-expanded?`:35, `filetree-toggle-expand`:38, `filetree-set-view`:45, `filetree-set-width`:46

## `plugins/filetree/panel.rkt`

**definitions**: `filetree-panel-view`:26, `sync-filetree-panel!`:29

## `plugins/filetree/plugin.rkt`

**definitions**: `pointer-keys`:47, `filetree-plugin-mode`:52, `filetree-panel-spec`:55, `install-filetree-panel!`:63, `filetree-plugin`:76

## `plugins/filetree/scan.rkt`

**definitions**: `filetree-normalize-path`:24, `entry-kind`:27, `name<?`:33, `dir-entries`:37

## `plugins/highlight/depth-decor.rkt`

**definitions**: `wrap-bg`:20, `scan-line`:22, `depth-open`:26, `depth-change`:35, `depth-face-decor`:46

## `plugins/highlight/depth-plugin.rkt`

**definitions**: `depth-bg-plugin`:17

## `plugins/highlight/depth.rkt`

**definitions**: `max-depth`:18, `depth-face-of`:21, `open->close`:35, `open-ch?`:36, `close-ch?`:37, `bracket-entry?`:38, `string-entry?`:39, `block-entry?`:40, `matches?`:41, `stack-level`:44, `depth-line`:48, `vector->fills`:111, `depth-fills`:123

## `plugins/highlight/kind.rkt`

**definitions**: `racket-extensions`:13, `racket-path?`:15, `racket-doc-meta?`:21

## `plugins/highlight/lex.rkt`

**definitions**: `symbol-char?`:27, `keyword-set`:31, `keyword-faces`:39, `keyword-face`:62, `lex-line`:66, `word-fills`:110, `syntax-line`:129, `merge-fills`:146, `lex-fills`:167

## `plugins/highlight/plugin.rkt`

**definitions**: `highlight-plugin`:20

## `plugins/highlight/syntax-decor.rkt`

**definitions**: `init-state`:20, `wrap-fg`:23, `scan-line`:25, `syntax-open`:29, `syntax-change`:38, `syntax-face-decor`:49

## `plugins/highlight/word-color-decor.rkt`

**definitions**: `word-color-count`:18, `word-hash`:21, `word-color-line`:25, `word-color-open`:42, `word-color-change`:45, `word-color-face-decor`:54

## `plugins/highlight/word-color-plugin.rkt`

**definitions**: `word-color-plugin`:14

## `plugins/highlight/words-decor.rkt`

**definitions**: `words-line`:17, `words-open`:35, `words-change`:38, `words-face-decor`:54

## `plugins/highlight/words-plugin.rkt`

**definitions**: `words-plugin`:14

## `plugins/lang/context.rkt`

**definitions**: `focused-vid`:28, `doc-meta-of-view`:32, `open-local-texts`:36, `source-context`:43, `export-key`:70

## `plugins/lang/doc-html.rkt`

**structs**: `cursor`:47

**definitions**: `xref`:35, `docs-uri-for-tag`:38, `make-cursor`:48, `cursor-can-go-down?`:50, `cursor-can-go-up?`:52, `cursor-can-go-left?`:54, `cursor-can-go-right?`:56, `cursor-go-down`:59, `cursor-go-up`:64, `cursor-go-up-until-true`:70, `cursor-go-left`:75, `cursor-go-right`:80, `cursor-go-to-next-sibling-or-uncle-node`:85, `find-doc-beginning-and-take-cursor`:99, `selected-node-contains-documentation-boundary?`:124, `collect-docs`:146, `tag?`:163, `tag-name?`:165, `get-tag-attribute`:167, `tag-attribute?`:170, `is-blockquote-leftindent?`:172, `html->markdown`:176, `make-proper-url-for-online-documentation`:259, `extract-documentation`:287, `weak-cache`:319, `extract-documentation-for-selected-element`:320

## `plugins/lang/docs.rkt`

**structs**: `doc`:32

**definitions**: `xref`:36, `bluebox-cache`:37, `doc-cache`:38, `bluebox-dir-caches`:43, `docs-lock`:49, `tag-for`:52, `docs-for`:58, `tag->doc`:66, `fetch-strs`:72, `tag-dir`:77, `tag->bluebox`:86, `tag->html-body`:98, `doc->text`:110, `doc->result`:122, `result->doc`:123

## `plugins/lang/local-docs.rkt`

**definitions**: `snippet-width`:19, `form->string`:22, `def-snippets`:31, `local-defs`:54, `local-def`:60

## `plugins/lang/module-index.rkt`

**definitions**: `rkt-exts`:19, `rkt-file?`:21, `rel->module`:25, `dir-modules`:30, `collects-modules`:38, `deny-dirs`:43, `pkg-modules`:46, `module-paths`:58

## `plugins/lang/pool.rkt`

**definitions**: `exports-cache`:33, `module-exports`:38, `distinct-strings`:51, `spec-names`:62, `local-module-path`:97, `spec-local-paths`:104, `spec-renames`:121, `spec-binding-of`:136, `spec-binding-in`:139, `leaf-module`:181

## `plugins/lang/source.rkt`

**definitions**: `line-end`:29, `skip-sexp-comment`:37, `skip-leading-trivia`:47, `directive-lang`:81, `strip-reader-lines`:87, `read-forms`:98, `module-context`:117, `requires-max-forms`:132, `requires-max-chars`:133, `requires-context`:134, `require-wrappers`:141, `list-elems`:145, `spec->paths`:153, `requires-of-forms`:177, `require-specs-of-forms`:189, `define-names`:199, `def-names`:206, `distinct-symbols`:222, `definitions-of-forms`:230, `distinct-strings`:235, `struct-fields`:248, `struct-out-names`:259, `contract-out-name`:266, `provide-names`:270, `provides-of-forms`:299, `text-before`:312, `last-open-paren`:322, `tokens`:349, `module-heads`:355, `first-arg-heads`:356, `lang-context?`:359, `require-context?`:374

## `plugins/resource/commands.rkt`

**definitions**: `message`:41, `selected-line`:45, `doc-views`:50, `selected-view`:56, `selected-doc`:65, `toggle-collapse-command`:69, `resource-enter-command`:83, `new-view-command`:108, `notice-state`:119, `new-doc-command`:122, `start-placement-command`:130, `detach-selected-command`:141, `close-selected-command`:156, `nav-command`:166, `resource-keys`:173, `resource-command-table`:189

## `plugins/resource/lines.rkt`

**structs**: `resource-line`:26

**definitions**: `listed-doc?`:33, `doc-label`:36, `doc-views`:39, `resource-lines`:45, `resource-line-at`:88, `resource-doc-line?`:94, `resource-view-line?`:95

## `plugins/resource/model.rkt`

**structs**: `resource-panel`:26

**definitions**: `resource-panel-empty`:30, `resource-panel-collapsed?`:32, `resource-panel-toggle-collapse`:35, `resource-panel-set-view`:42

## `plugins/resource/panel.rkt`

**definitions**: `resource-view`:26, `sync-resource-panel!`:29

## `plugins/resource/plugin.rkt`

**definitions**: `pointer-keys`:37, `resource-plugin-mode`:42, `resource-panel-spec`:45, `install-resource-panel!`:53, `resource-plugin`:59

## `plugins/worker.rkt`

**definitions**: `service-kinds`:45, `service-run`:48, `syntax-fills-for`:75, `depth-fills-for`:81

## `projection/float.rkt`

**structs**: `float-panel`:29

**definitions**: `float-borders`:35, `max-rows`:36, `frame-area`:38, `float-lines`:43, `float-size`:48, `anchor-area`:56, `float-rect`:72, `project-floats`:102, `float-panel-at`:107

## `projection/geometry.rkt`

**structs**: `region-panel`:42, `cut`:48

**definitions**: `leaf-effective-borders`:58, `axis-thickness`:64, `int-alloc`:75, `clamp`:91, `scale-to`:97, `alloc-flex`:103, `alloc-dims`:141, `rect-content`:171, `solve`:178, `geometry-solve`:228, `region-panel-map`:230, `window-area`:237, `region-parent-axis`:241, `region-content-size`:253, `region-neighbor`:263, `region-panel-at`:277, `cut-match?`:284, `cuts-at`:291, `cut-at`:294, `node-at-path`:299, `next-visible-index`:302, `tree-resize-at`:308, `resize-dims`:325, `tree-resize-seam`:342

## `projection/render.rkt`

**structs**: `frame-cache`:45

**definitions**: `frame-area`:52, `active-member`:56, `project-frame`:64, `project-view-placements`:113, `render-frame`:121

## `projection/status.rkt`

**definitions**: `chrome-slot-view?`:45, `first-editor-view`:51, `status-view`:64, `status-position`:71, `display-doc-path`:79, `status-path`:95, `status-sequence`:102, `status-message`:106, `status-position-part`:117, `status-path-part`:123, `status-sequence-part`:126, `status-message-part`:129, `default-status-parts`:133, `full-status-parts`:137, `status-line`:142, `state-line`:152

## `runtime/run.rkt`

**definitions**: `subject-for`:60, `ensure-doc-decors!`:85, `settle`:107, `process-events`:124, `drain-and-process`:136, `run-transition-effects`:147, `run-one-effect`:156, `inline-service-run`:194, `drain-channel`:202, `startup!`:214, `state-frame-syncs`:242, `run-frame`:247, `run-app`:263

## `runtime/tui-adapter.rkt`

**definitions**: `tui-event->app`:19

## `runtime/worker.rkt`

**structs**: `worker`:34

**definitions**: `worker-entry-path`:39, `worker-start!`:48, `worker-submit!`:83, `worker-stop!`:88

## `theme/core.rkt`

**definitions**: `core-theme`:16

## `theme/frame.rkt`

**definitions**: `frame-theme`:14

## `theme/theme.rkt`

**structs**: `rgb`:25, `style`:27

**definitions**: `color-fg-thunk`:31, `color-bg-thunk`:36, `attr-thunk`:41, `install-style!`:47, `define-theme!`:55


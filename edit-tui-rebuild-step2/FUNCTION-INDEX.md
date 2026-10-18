# Function Index

> 自动生成：`edit-tui-rebuild-step2` 下除 `test/`、`demo/`、`compiled/` 外的所有**顶层** `struct` / `define` / `define-syntax`。
> 行号只用于导航；`struct` 行不展开自动生成的构造器 / 谓词 / 访问器。

## `base/effect.rkt`

**structs**: `edit-effect`:70, `insert-text-effect`:71, `set-text-effect`:72, `set-input-prompt-effect`:73, `set-face-layer-effect`:80, `replace-range-effect`:82, `ensure-view-effect`:84, `submit-service-effect`:91, `query-effect`:94, `select-effect`:95, `scroll-effect`:96, `nav-effect`:97, `undo-effect`:98, `redo-effect`:99, `open-doc-effect`:100, `open-view-effect`:101, `close-view-effect`:102, `close-doc-effect`:103, `save-doc-effect`:104, `read-file-effect`:105, `write-file-effect`:106, `make-directory-effect`:107, `delete-file-effect`:108, `spawn-effect`:109, `timer-effect`:110, `emit-effect`:111, `quit-effect`:112

**definitions**: `effect?`:114, `effect-kind`:127

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

## `bootstrap/commands/cancel.rkt`

**definitions**: `cancel-current-command`:35

## `bootstrap/commands/document.rkt`

**definitions**: `confirm-cancel-state`:57, `confirm-cancel`:60, `mount-opened-document`:64, `open-file-from-path`:71, `open-file-prompt-command`:95, `close-doc-action*`:99, `doc-dirty?`:104, `saveable-doc?`:111, `dirty-docs`:114, `doc-label`:120, `save-confirm-label`:124, `close-doc-action`:127, `confirm-current-doc`:148, `save-confirm-show`:156, `save-confirm-show-state`:162, `save-confirm-start`:168, `confirm-next`:181, `confirm-finish`:195, `confirm-save-current`:206, `save-docs-then`:231, `input-submit-command`:263, `input-cancel-command`:279, `handle-save-answer`:283, `save-doc-to-path`:304, `save-current-command`:330, `default-input-commands`:355, `request-quit-command`:379, `request-close-doc`:388, `request-close-file-command`:397, `close-file-command`:406

## `bootstrap/commands/edit.rkt`

**definitions**: `nav-command`:26, `insert-command`:33, `edit-command`:40, `undo-command`:47, `redo-command`:53, `quit-command`:59

## `bootstrap/commands/focus.rkt`

**definitions**: `focus-move-command`:35, `focus-move`:38, `screen->point`:62, `pointer-press-command`:87, `pointer-drag-command`:109

## `bootstrap/commands/layout.rkt`

**definitions**: `focus-in-region?`:31, `fallback-view-outside`:41, `region-dim-size`:51, `toggle-region!`:55

## `bootstrap/commands/placement.rkt`

**definitions**: `set-placement`:38, `clear-placement`:43, `placement-cancel`:49, `place-cancel-command`:52, `place-into`:63, `place-commit-command`:109, `place-at-command`:112, `placement-scope`:115, `placement-keys`:118

## `bootstrap/commands/region.rkt`

**definitions**: `subject-region`:28, `count-role-regions`:36, `last-region-of-role?`:42, `drop-region-views`:46, `fallback-view`:53, `close-region-command`:59, `close-region`:62

## `bootstrap/commands/table.rkt`

**definitions**: `default-command-table`:22

## `bootstrap/commands/util.rkt`

**definitions**: `message`:37, `view-subject`:41, `region-subject`:47, `input-busy?`:55, `frame-area`:57, `notice-state-value`:60, `notice-state`:63, `real-view?`:68, `fallback-attached-view`:72

## `bootstrap/commands/view.rkt`

**definitions**: `split-region-command`:44, `split-region`:54, `axis/side`:69, `mount-split`:77, `close-view-command`:99, `close-view`:102, `region-has-view?`:129, `target-region-for-new-view*`:134, `target-region-for-new-view`:145, `mount-view-in-region`:148, `new-document-command`:156, `detach-view-command`:174, `attach-detached-command`:191, `switch-member-command`:223

## `bootstrap/defaults.rkt`

**definitions**: `text-keys`:42, `pointer-keys`:56, `nav-keys`:62, `input-keys`:72, `core-global-keys`:84, `core-env`:112

## `bootstrap/panel.rkt`

**definitions**: `panel-spec-install!`:25

## `bootstrap/plugin.rkt`

**definitions**: `plugin-uninstall!`:30

## `chrome/input.rkt`

**definitions**: `input-active?`:44, `input-value`:47, `input-cancel`:65, `input-interaction`:82, `input-show`:87, `input-show-state`:100

## `chrome/slot.rkt`

**definitions**: `install-chrome!`:35, `chrome-slot*`:53, `chrome-status-view`:56, `chrome-input-view`:60, `chrome-show-view`:64, `chrome-show-input`:77, `chrome-show-status`:81, `input-view`:93, `input-show`:97, `input-finish`:112, `input-read-text`:123, `input-write-prompt`:128, `sync-chrome!`:138

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

**definitions**: `dispatch`:49, `message-expiring-event?`:88, `state-set-pending`:98, `state-clear-pending`:105, `cancel-token?`:110, `dispatch-key`:117, `dispatch-key-normal`:135, `dispatch-mouse`:155, `dispatch-mouse*`:160, `dispatch-resize`:220, `dispatch-paste`:225, `run-command`:232, `dispatch-unbound`:255, `sequence->string`:269, `token-text`:273, `focusable-subject?`:286, `notice`:294

## `dispatch/rules.rkt`

**definitions**: `subject-doc-meta`:37, `subject-mode-id`:42, `input-mode-rules`:48, `doc-layer-rules`:52, `mode-rules`:57, `global-rules`:64, `extra-rules`:68, `rules-for`:75, `prefix-rules`:88, `lookup-rules`:95

## `effects/engine.rkt`

**structs**: `engine`:66, `engine-view`:343, `open-doc-spec`:415

**definitions**: `make-engine`:73, `engine-set-face-layers!`:79, `engine-set-face-layer!`:84, `engine-attach-decors!`:91, `engine-decors-attached?`:101, `engine-paint-advance!`:105, `reset-paint-for-buffer!`:113, `engine-doc-buffer`:123, `engine-view-object`:126, `engine-doc-exists?`:129, `engine-view-exists?`:130, `engine-add-doc!`:132, `engine-add-view!`:136, `engine-create-doc!`:143, `engine-create-view!`:148, `engine-sync-view!`:160, `engine-ensure-view!`:173, `engine-sync-views!`:179, `engine-set-view-text!`:189, `engine-remove-view!`:205, `engine-remove-doc!`:213, `engine-effect?`:228, `engine-apply!`:237, `engine-replace-range!`:294, `engine-undo-redo!`:301, `whole-range`:313, `whole-change`:321, `need-view`:324, `apply-nav!`:328, `make-engine-view`:345, `ev-buffer`:347, `ev-view`:350, `engine-view-doc-text`:353, `engine-view-doc-name`:357, `engine-view-view-text`:361, `engine-view-view-readonly-at?`:365, `engine-view-doc-version`:371, `engine-version=?`:375, `engine-view-view-point`:377, `engine-view-view-point-line`:381, `engine-view-view-point-column`:385, `engine-view-view-selections`:389, `engine-view-view-cursor-position`:393, `engine-view-view-screen-position->point`:397, `engine-view-view-width`:401, `engine-view-view-height`:405, `engine-view-view-line-numbers?`:409, `make-open-doc-spec`:417, `open-doc-effect*`:425

## `effects/interpreter.rkt`

**definitions**: `runtime-effect?`:43, `interpret-effect!`:49, `interpret-replace-range!`:145, `edit-write?`:160, `effect-doc`:166, `interpret-open-doc!`:178, `interpret-open-view!`:204, `interpret-save-doc!`:218, `interpret-effects!`:252, `interpret-effect-tree!`:258

## `effects/paint.rkt`

**structs**: `paint-state`:49

**definitions**: `paint-state-of`:59, `set-paint-state!`:62, `paint-open!`:69, `paint-reset!`:83, `paint-fork`:88, `paint-advance!`:128, `paint-set-static-layer!`:152, `fills->layer-track`:165, `paint-write!`:185

## `effects/panel.rkt`

**definitions**: `panel-create-view!`:59, `panel-region-add!`:78, `panel-region-install!`:101, `panel-install!`:115, `panel-visible?`:127, `panel-uninstall!`:144, `panel-uninstall-view!`:172, `panel-sync-buffer!`:192

## `env/command.rkt`

**definitions**: `command-run/ctx`:43, `command-note-text`:47

## `env/defaults.rkt`

**definitions**: `default-roles`:18, `default-modes`:29, `default-environment`:34

## `env/doc-type.rkt`

**structs**: `doc-type`:26

**definitions**: `make-doc-type`:32, `path-extension`:46, `doc-type-matches-path?`:50

## `env/environment.rkt`

**structs**: `environment`:83

**definitions**: `environment-empty`:106, `make-environment`:109, `environment-role`:132, `environment-mode`:135, `environment-command`:138, `environment-keymap`:141, `environment-doc-type`:144, `environment-doc-type-for-path`:147, `environment-mode-keymaps`:153, `environment-add-role`:158, `environment-add-mode`:162, `environment-add-scope`:166, `environment-add-command`:170, `environment-add-keymap`:175, `environment-add-rule`:181, `environment-add-status-part`:184, `environment-add-status-parts`:188, `environment-add-doc-type`:194, `environment-add-input-command`:198, `environment-add-panel-sync`:202, `environment-add-panel-syncs`:207, `environment-add-hook`:211, `environment-add-hooks`:215, `environment-add-face-layer`:219, `environment-add-face-layers`:223, `environment-add-decor`:227, `environment-add-interaction`:231, `environment-interaction`:237, `environment-service`:240, `environment-service-kinds`:242, `environment-add-service`:245, `environment-add-decors`:252, `environment-merge`:256

## `env/extension.rkt`

**structs**: `contribution`:77, `validation-error`:288

**definitions**: `contribution-kinds`:69, `contribution-kind?`:74, `make-contribution`:101, `environment-add-contribution`:111, `environment-add-contributions`:203, `environment-strip-contributions`:211, `environment-attach-contributions`:217, `environment->contributions`:228, `environment-remove-owner`:267, `environment-owner-contributions`:281, `err`:292, `keymap-leaf-values`:296, `check-keymap`:303, `check-unique-name`:310, `validate-environment`:319, `validate-environment!`:462, `environment-valid?`:474

## `env/hook.rkt`

**structs**: `hook`:29

**definitions**: `make-hook`:35

## `env/input-command.rkt`

**structs**: `input-command`:22

**definitions**: `make-input-command`:28, `input-command-prefix`:32, `input-command-regexp`:40, `input-command-list`:45

## `env/mode.rkt`

**structs**: `mode`:22

**definitions**: `make-mode`:26, `mode-default`:34

## `env/panel-spec.rkt`

**structs**: `panel-spec`:22

**definitions**: `make-panel-spec`:34

## `env/plugin.rkt`

**structs**: `plugin`:61

**definitions**: `make-plugin`:63, `plugin-env-apply`:100, `plugins-env`:133, `plugins-apply`:139

## `env/role.rkt`

**structs**: `role`:23

**definitions**: `make-role`:30, `role-default`:39

## `env/rule.rkt`

**structs**: `rule`:19

**definitions**: `make-rule`:23

## `env/scope.rkt`

**structs**: `scope`:26

**definitions**: `make-scope`:29, `scope-known?`:34, `scope-ok?`:37

## `env/service.rkt`

**structs**: `service-spec`:19

**definitions**: `make-service-spec`:24

## `model/chrome.rkt`

**structs**: `chrome-slot`:22, `chrome`:27

**definitions**: `make-chrome-slot`:24, `chrome-empty`:32, `make-chrome`:34, `chrome-set-message`:37, `chrome-clear-message`:38, `chrome-log-append`:39, `chrome-set-slot`:41

## `model/face-decor.rkt`

**structs**: `face-decor`:72, `face-ctx`:79, `dirty`:89

**definitions**: `dirty-all`:91, `dirty-lines`:92, `dirty-empty?`:93, `dirty-union`:95, `dirty->lines`:101, `change-line-span`:108, `changes->dirty-lines`:112, `scan-track`:121, `blank-layer-track`:127, `refresh-layer`:137, `change-spans`:167, `stateful-advance`:182, `face-runs`:228

## `model/face-layer.rkt`

**definitions**: `compose-face`:42, `compose-layers`:60

## `model/input.rkt`

**structs**: `gesture`:23, `input-session`:38, `input`:49

**definitions**: `idle-gesture?`:28, `make-gesture`:29, `make-input-session`:40, `input-empty`:55, `make-input`:57, `input-pending?`:63, `input-clear-pending`:64, `input-set-pending`:65, `input-push-mode`:66, `input-pop-mode`:67, `input-set-gesture`:70, `input-set-session`:71

## `model/interaction.rkt`

**structs**: `interaction`:39

**definitions**: `interaction-empty`:41, `make-interaction`:43, `interaction-top`:50, `interaction-push`:53, `interaction-pop`:56, `interaction-pop-id`:60, `interaction-pop-kind`:67, `interaction-find`:73

## `model/layout.rkt`

**structs**: `dim`:39, `leaf`:51, `split`:52

**definitions**: `fixed`:43, `flex`:44, `->dim`:45, `dim-fixed?`:46, `dim-flex?`:47, `leaf-borders-all`:54, `leaf-borders-none`:55, `node?`:57, `node-dim`:58, `node-visible?`:59, `node-with-dim`:62, `make-leaf`:66, `make-split`:71, `empty-tree`:76, `empty-tree?`:77, `tree-find`:81, `tree-contains?`:85, `tree-leaves`:87, `tree-regions`:91, `tree-visible-leaves`:93, `tree-visible-regions`:98, `tree-visible?`:100, `map-leaves`:106, `tree-set-dim`:113, `tree-set-visible`:117, `tree-set-borders`:121, `tree-show`:125, `tree-hide`:126, `tree-insert`:138, `tree-split`:173, `tree-detach`:186, `tree-close`:201, `tree-move`:205

## `model/save.rkt`

**structs**: `save-confirm`:21

**definitions**: `make-save-confirm`:23

## `model/service.rkt`

**structs**: `service-state`:40

**definitions**: `service-empty`:45, `service-cache-ref`:49, `service-cache-has?`:52, `service-cache-set`:55, `service-cache-remove`:59, `service-pending?`:65, `service-pending-add`:68, `service-pending-del`:72, `service-job-add`:78, `service-job-tag`:82, `service-job-take`:85, `service-request`:94

## `model/state.rkt`

**structs**: `window`:52, `runtime`:59, `state`:69

**definitions**: `make-window`:55, `make-runtime`:64, `make-state`:71, `state-empty`:83, `state-set-window`:87, `state-set-workspace`:88, `state-set-input`:89, `state-set-chrome`:90, `state-set-runtime`:91, `state-set-ids`:92, `state-set-confirm`:93, `state-set-store`:94, `state-set-signals`:95, `state-set-interactions`:96, `state-workspace*`:99, `state-input*`:100, `state-chrome*`:101, `state-runtime*`:102, `state-confirm*`:103, `state-store*`:104, `state-interactions*`:105, `state-interaction-top`:109, `state-interaction-push`:112, `state-interaction-pop-id`:115, `state-interaction-pop-kind`:119, `state-emit`:126, `state-drain-signals`:130, `plugin-state`:138, `plugin-state-set`:140, `plugin-state*`:142, `plugin-state-clear`:145, `state-mark-quit`:148, `state-bump-revision`:150, `state-next-id`:154, `state-focus`:160, `state-input-active?`:163, `state-set-focus`:170

## `model/workspace.rkt`

**structs**: `doc-meta`:70, `view-meta`:89, `region-member`:95, `region`:104, `float`:115, `panel-entry`:123, `workspace`:178

**definitions**: `make-doc-meta`:81, `view-member`:102, `view-region-member?`:103, `workspace-panel-register`:130, `workspace-panel-unregister-view`:139, `workspace-panel-unregister-region`:146, `workspace-panel-views-by-owner`:153, `workspace-panel-regions-by-owner`:158, `workspace-panel-view`:164, `workspace-panel-region`:170, `workspace-empty`:195, `make-workspace`:199, `workspace-set-root`:211, `workspace-set-placement`:214, `workspace-float`:219, `workspace-add-float`:224, `drop-floats`:231, `workspace-remove-float`:234, `workspace-doc`:242, `workspace-view`:243, `workspace-region`:244, `workspace-doc-of-view`:246, `workspace-view-region`:250, `workspace-region-members`:256, `workspace-region-active`:260, `workspace-region-views`:264, `workspace-add-doc`:271, `workspace-add-view`:274, `workspace-add-region`:277, `remove-view-from-regions`:283, `workspace-detach-view`:299, `workspace-attach-view`:303, `workspace-view-attached?`:321, `workspace-detached-views`:324, `workspace-remove-view`:335, `workspace-remove-region`:362, `workspace-remove-doc`:371, `workspace-focus-view`:382, `workspace-set-focus`:385, `workspace-set-focus*`:394, `workspace-pop-focus`:400

## `plugins/builtin.rkt`

**definitions**: `default-plugins`:33, `default-env`:37, `editor-plugins`:42, `editor-env`:54

## `plugins/completion/plugin.rkt`

**definitions**: `store-key`:60, `popup-id`:61, `completion-mode-name`:62, `completion-store`:66, `store-ref`:72, `store-set`:73, `completion-session`:77, `set-session`:78, `completion-popup-view`:80, `popup-region`:81, `popup-float`:82, `install-completion-popup-state!`:88, `completion-panel-spec`:91, `install-completion-popup!`:100, `completion-open?`:104, `line-at`:108, `prefix-at`:114, `doc-words`:123, `open-doc-ids`:130, `local-words`:135, `base-pool`:141, `module-path-context?`:153, `filter-pool`:165, `rank-candidates`:172, `service-of`:181, `cache-get`:182, `cache-put`:184, `pending?`:187, `pending-del`:189, `job-take`:193, `submit-job`:198, `popup-window`:205, `session-candidates`:209, `session-index`:210, `session-name`:211, `session-binding`:215, `selection-state`:222, `popup-content`:228, `popup-doc`:245, `render-popup`:250, `open-popup`:269, `close-popup`:281, `msg`:294, `open-with-pool`:297, `maybe-open-cached`:309, `completion-open`:340, `completion-move`:382, `completion-refine-hook`:392, `completion-accept`:417, `completion-cancel`:441, `completion-noop`:444, `completion-on-job`:448, `completion-keys`:467, `completion-popup-keys`:471, `completion-doc-keys`:481, `completion-plugin`:487

## `plugins/docs/plugin.rkt`

**definitions**: `store-key`:53, `docs-store`:57, `store-ref`:62, `store-set`:63, `docs-panel-view`:69, `install-docs-panel-state!`:71, `docs-panel-spec`:74, `install-docs-panel!`:84, `docs-keys`:88, `docs-state`:98, `set-docs-state`:99, `service-of`:101, `cache-get`:102, `cache-has?`:103, `cache-put`:104, `pending?`:107, `pending-del`:108, `job-take`:112, `ident-char?`:119, `line-at`:123, `identifier-at`:129, `builtin-docs`:141, `doc-context`:169, `online-docs`:192, `origin-text`:195, `docs-lines`:203, `docs-text`:214, `docs-fills`:219, `docs-region`:230, `docs-open?`:234, `hide-docs`:238, `show-docs`:247, `docs-panel-doc`:257, `write-docs`:261, `submit-doc-job`:273, `docs-show-impl`:280, `docs-show-command`:323, `docs-toggle-command`:327, `docs-on-nav`:335, `docs-on-selection`:345, `docs-on-job`:353, `docs-keys-table`:383, `docs-plugin`:387

## `plugins/filetree/commands.rkt`

**definitions**: `message`:47, `notice-state`:51, `selected-line`:55, `selected-dir`:60, `doc-views`:69, `find-doc-by-path`:75, `ensure-editor-region`:83, `attach-and-focus`:107, `begin-open-placement`:116, `open-file-placement`:125, `filetree-min-size`:172, `toggle-filetree-command`:174, `filetree-enter-command`:197, `resolve-path`:214, `create-file-prompt-command`:218, `create-folder-prompt-command`:227, `delete-file-command`:236, `create-file-handler`:249, `delete-file-handler`:270, `create-folder-handler`:291, `filetree-input-commands`:312, `filetree-keys`:327, `nav-command`:340, `filetree-command-table`:347

## `plugins/filetree/lines.rkt`

**structs**: `filetree-line`:32

**definitions**: `open-doc-paths`:39, `indent`:44, `entry-name`:46, `filetree-lines`:49, `filetree-line-at`:80, `filetree-dir?`:86, `filetree-file?`:87

## `plugins/filetree/model.rkt`

**structs**: `filetree`:27

**definitions**: `empty-filetree`:29, `make-filetree`:31, `filetree-expanded?`:35, `filetree-toggle-expand`:38, `filetree-set-view`:45

## `plugins/filetree/panel.rkt`

**definitions**: `filetree-panel-view`:26, `sync-filetree-panel!`:29

## `plugins/filetree/plugin.rkt`

**definitions**: `pointer-keys`:48, `filetree-plugin-mode`:53, `install-filetree-panel-state!`:58, `filetree-panel-spec`:69, `install-filetree-panel!`:81, `filetree-plugin`:87

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

**definitions**: `message`:42, `selected-line`:46, `doc-views`:51, `selected-view`:57, `selected-doc`:66, `toggle-collapse-command`:70, `resource-enter-command`:84, `new-view-command`:109, `notice-state`:120, `new-doc-command`:123, `start-placement-command`:131, `detach-selected-command`:141, `close-selected-command`:156, `nav-command`:166, `resource-keys`:173, `resource-command-table`:189

## `plugins/resource/lines.rkt`

**structs**: `resource-line`:26

**definitions**: `listed-doc?`:33, `doc-label`:36, `doc-views`:39, `resource-lines`:45, `resource-line-at`:88, `resource-doc-line?`:94, `resource-view-line?`:95

## `plugins/resource/model.rkt`

**structs**: `resource-panel`:26

**definitions**: `resource-panel-empty`:30, `resource-panel-collapsed?`:32, `resource-panel-toggle-collapse`:35, `resource-panel-set-view`:42

## `plugins/resource/panel.rkt`

**definitions**: `resource-view`:26, `sync-resource-panel!`:29

## `plugins/resource/plugin.rkt`

**definitions**: `pointer-keys`:38, `resource-plugin-mode`:43, `install-resource-panel-state!`:46, `resource-panel-spec`:51, `install-resource-panel!`:63, `resource-plugin`:67

## `plugins/worker.rkt`

**definitions**: `service-kinds`:45, `service-run`:48, `syntax-fills-for`:75, `depth-fills-for`:81

## `projection/float.rkt`

**structs**: `float-panel`:29

**definitions**: `float-borders`:35, `max-rows`:36, `frame-area`:38, `float-lines`:43, `float-size`:48, `anchor-area`:57, `float-rect`:76, `project-floats`:106, `float-panel-at`:112

## `projection/geometry.rkt`

**structs**: `region-panel`:44, `cut`:50, `layout-snapshot`:54

**definitions**: `leaf-effective-borders`:64, `axis-thickness`:70, `int-alloc`:81, `clamp`:97, `scale-to`:103, `alloc-flex`:109, `alloc-dims`:147, `rect-content`:177, `solve`:184, `geometry-solve`:234, `geometry-snapshot`:236, `region-panel-map`:240, `window-area`:247, `region-parent-axis`:251, `region-content-size`:263, `region-neighbor`:273, `region-panel-at`:287, `cut-match?`:294, `cuts-at`:301, `cut-at`:304, `node-at-path`:309, `next-visible-index`:312, `tree-resize-at`:318, `resize-dims`:335, `tree-resize-seam`:352

## `projection/render.rkt`

**structs**: `frame-cache`:48

**definitions**: `frame-area`:55, `active-member`:59, `project-frame`:67, `project-view-placements`:118, `render-frame`:129, `render-frame*`:133

## `projection/status.rkt`

**definitions**: `chrome-slot-view?`:45, `first-editor-view`:51, `status-view`:64, `status-position`:71, `display-doc-path`:79, `status-path`:95, `status-sequence`:102, `status-message`:106, `status-position-part`:117, `status-path-part`:123, `status-sequence-part`:126, `status-message-part`:129, `default-status-parts`:133, `full-status-parts`:137, `status-line`:142, `state-line`:152

## `runtime/run.rkt`

**definitions**: `subject-for`:60, `ensure-doc-decors!`:85, `settle`:107, `process-events`:124, `drain-and-process`:136, `run-transition-effects`:147, `run-one-effect`:156, `inline-service-run`:200, `drain-channel`:208, `ensure-service-kinds!`:220, `startup!`:227, `state-frame-syncs`:257, `run-frame`:262, `run-app`:279

## `runtime/tui-adapter.rkt`

**definitions**: `tui-event->app`:19

## `runtime/worker.rkt`

**structs**: `worker`:35

**definitions**: `worker-entry-path`:40, `worker-known-service-kinds`:50, `worker-start!`:54, `worker-submit!`:89, `worker-stop!`:94

## `theme/core.rkt`

**definitions**: `core-theme`:16

## `theme/frame.rkt`

**definitions**: `frame-theme`:14

## `theme/theme.rkt`

**structs**: `rgb`:25, `style`:27

**definitions**: `color-fg-thunk`:31, `color-bg-thunk`:36, `attr-thunk`:41, `install-style!`:47, `define-theme!`:55


#lang racket

;;; 双语插件：源 user doc <-> derived mirror
;;;   · 源编辑 -> mirror 行刷新
;;;   · mirror 编辑 -> 反译回源 -> mirror 重投影
;;;   · 关闭源 -> mirror 清理

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../app/actions.rkt"
         "../app/event.rkt"
         "../core/command/api.rkt"
         "../host/event.rkt"
         "../edit.rkt"
         "../host/close.rkt"
         "../host/layout.rkt"
         "../core/layout/api.rkt"
         (only-in "../core/panel/api.rkt" panel-face)
         "../plugins/bilingual/api.rkt"
         "fixture.rkt")

(define sample
  (string-append "#lang racket\n"
                 "\n"
                 "(define (main xs)\n"
                 "  (map add1 xs))\n"))

(define-values (ed state0)
  (make-editor-app #:initial-text sample
                   #:initial-name "test.rkt"
                   #:initial-resource? #t))

(define source-did 1)
(define source-vid 1)

;; M-l 走插件 command -> action -> host 打开 pair。
(define state1
  (handle-editor-event ed state0 (key-event (key 'l 'alt))))
(define state2 (run-plugin-syncs ed state1))

(define ps (state-plugin-state state2 'bilingual))
(define p (bilingual-pair-for-source ps source-did))
(check-not-false p)
(define mirror-did (pair-mirror-doc-id p))
(define mirror-vid (pair-mirror-view-id p))

;; mirror 是 derived，不是 ui，也不在 user-doc 集合里。
(check-equal? (engine-doc-kind (editor-engine ed) mirror-did) 'derived)
(check-not-false (memv mirror-did (editor-derived-doc-ids ed)))
(check-false (memv mirror-did (editor-user-doc-ids ed)))
(check-true (string-contains? (editor-doc-text ed mirror-did) "定义"))
(check-true (string-contains? (editor-doc-text ed mirror-did) "映射"))
(check-true (string-contains? (editor-doc-text ed mirror-did) "(main xs)"))
(check-equal? (length (editor-visible-editor-panels state2)) 2)
(check-equal? (engine-view-face-at (editor-engine ed) mirror-did 2 1)
              'bilingual-keyword)
(check-equal? (engine-view-face-at (editor-engine ed) mirror-did 3 3)
              'bilingual-function)
(define source-pid (editor-view-panel-id state2 source-vid))
(define mirror-pid (editor-view-panel-id state2 mirror-vid))
(check-not-equal? source-pid mirror-pid)
;; 焦点框由 core 画；bilingual 不再给 source / mirror panel 设置常驻边框色。
(check-equal? (panel-face (layout-panel (state-layout state2) source-pid))
              'window-border)
(check-equal? (panel-face (layout-panel (state-layout state2) mirror-pid))
              'window-border)

;; viewport 同步：mirror 作为 leader 时源行跟随。
(editor-set-view-anchor-point! ed mirror-vid (point 3 0))
(define state2-anchor1 (run-plugin-syncs ed state2))
(check-equal? (point-line (editor-view-anchor-point ed source-vid)) 3)
(check-equal? (point-column (editor-view-anchor-point ed source-vid)) 0)

(define-values (state2-focus _a2-focus attached?)
  (editor-focus-view-if-attached! ed state2-anchor1 source-vid))
(check-true attached?)
(define source-lines (string-split (editor-doc-text ed source-did) "\n" #:trim? #f))
(define mirror-lines (string-split (editor-doc-text ed mirror-did) "\n" #:trim? #f))
(define vp-line 3)
(define src-line (list-ref source-lines vp-line))
(define mir-line (list-ref mirror-lines vp-line))
(define src-col (quotient (string-length src-line) 2))
(define expected-col
  (round (* (/ src-col (string-length src-line))
            (string-length mir-line))))

;; 顶部行放在 vp-line 之外，列比例仍按光标行 vp-line 计算。
(define anchor-line 2)
(editor-set-view-cursor! ed source-vid vp-line #:column src-col)
(editor-set-view-anchor-point! ed source-vid (point anchor-line src-col))
(define state2-scroll3 (run-plugin-syncs ed state2-focus))
(check-equal? (point-line (editor-view-anchor-point ed mirror-vid)) anchor-line)
(check-equal? (point-column (editor-view-anchor-point ed mirror-vid)) expected-col)

;; 源编辑：替换源第 3 行（0 基），mirror 对应行更新。
(define-values (state3 _actions3)
  (editor-replace-lines! ed state2-scroll3 source-vid 3 4
                         (list "(define (add a b)")))
(define mirror-text3 (editor-doc-text ed mirror-did))
(check-true (string-contains? mirror-text3 "(定义 (add a b)"))
(check-true (string-contains? mirror-text3 "(main xs)"))

;; mirror 编辑：在 mirror 第 3 行末尾插入注释，反译回源。
(define mirror-line (list-ref (string-split (editor-doc-text ed mirror-did) "\n" #:trim? #f) 3))
(engine-set-view-cursor! (editor-engine ed) mirror-vid 3
                         #:column (string-length mirror-line))
(define state4 state3)
(define-values (state5 actions5)
  (editor-insert! ed state4 mirror-vid " ;mirror"))
(define state6 (run-actions ed state5 actions5))
(define source-text6 (editor-doc-text ed source-did))
(check-true (string-contains? source-text6 "(define (add a b) ;mirror"))
(check-true (string-contains? (editor-doc-text ed mirror-did) ";mirror"))

;; 再跑一帧同步，不应产生新的源变化 / 不应回环。
(define state7 (run-plugin-syncs ed state6))
(check-equal? (editor-doc-text ed source-did) source-text6)

;;; ════════════════ C-w d 只 detach mirror panel，M-l 重新挂回 ════════════════

(define mirror-text7 (editor-doc-text ed mirror-did))
(define-values (state-mirror-focus _a-mirror-focus attached-mirror?)
  (editor-focus-view-if-attached! ed state7 mirror-vid))
(check-true attached-mirror?)
(define-values (state-detached _a-detached)
  (editor-close! ed state-mirror-focus))
(check-false (editor-view-panel-id state-detached mirror-vid))
;; panel 关了，但 mirror doc / pair 都还在。
(check-not-false (engine-doc-kind (editor-engine ed) mirror-did))
(check-not-false (bilingual-pair-for-source
                  (state-plugin-state state-detached 'bilingual)
                  source-did))
(check-equal? (editor-doc-text ed mirror-did) mirror-text7)

;; 回到 source 按 M-l：已有 pair 且 mirror detached -> host 重新 attach。
(define-values (state-source _a-source attached-source?)
  (editor-focus-view-if-attached! ed state-detached source-vid))
(check-true attached-source?)
(define state-reattach
  (handle-editor-event ed state-source (key-event (key 'l 'alt))))
(define state-reattach-sync (run-plugin-syncs ed state-reattach))
(define mirror-pid-2 (editor-view-panel-id state-reattach-sync mirror-vid))
(check-not-false mirror-pid-2)
(check-not-equal? mirror-pid-2
                  (editor-view-panel-id state-reattach-sync source-vid))
(check-equal? (panel-face (layout-panel (state-layout state-reattach-sync)
                                       mirror-pid-2))
              'window-border)
(check-equal? (editor-doc-text ed mirror-did) mirror-text7)

;;; ════════════════ M-l 关闭 pair 后，仍能从 source 重新创建 ════════════════

;; reattach 后 mirror 是 focused view；M-l 关闭 pair。
(define state-closed
  (handle-editor-event ed state-reattach-sync (key-event (key 'l 'alt))))
(check-false (bilingual-pair-for-source
              (state-plugin-state state-closed 'bilingual)
              source-did))
(check-false (engine-doc-kind (editor-engine ed) mirror-did))
;; 关闭 pair 后焦点回到 source，而不是 sidebar / filetree。
(check-equal? (editor-focus-view-id state-closed) source-vid)
(check-true (string-contains? (state-flash state-closed) "closed"))

;; 同一个 source 再按 M-l：重新创建 pair / derived mirror。
(define state-reopened
  (handle-editor-event ed state-closed (key-event (key 'l 'alt))))
(define state-reopened-sync (run-plugin-syncs ed state-reopened))
(define p-reopened
  (bilingual-pair-for-source
   (state-plugin-state state-reopened-sync 'bilingual)
   source-did))
(check-not-false p-reopened)
(check-not-equal? (pair-mirror-doc-id p-reopened) mirror-did)
(check-true (string-contains?
             (editor-doc-text ed (pair-mirror-doc-id p-reopened))
             "定义"))

;; 关闭源：mirror doc / pair 都清理。
(define-values (state8 _a8)
  (editor-close-resource! ed state-reopened-sync source-did))
(check-false (engine-doc-kind (editor-engine ed) mirror-did))
(check-false (bilingual-pair-for-source (state-plugin-state state8 'bilingual)
                                        source-did))
(check-equal? (length (editor-visible-editor-panels state8)) 1)
(check-equal? (panel-face (layout-panel (state-layout state8) 'editor))
              'window-border)

;;; ════════════════ M-l 只对 Racket buffer 生效 ════════════════

(define-values (ed-text state-text0)
  (make-editor-app #:initial-text "plain text\n"
                   #:initial-name "note.txt"
                   #:initial-resource? #t))
(define state-text1
  (handle-editor-event ed-text state-text0 (key-event (key 'l 'alt))))
(check-false (bilingual-pair-for-source
              (state-plugin-state state-text1 'bilingual)
              1))
(check-true (string-contains? (state-flash state-text1) "Racket"))

(displayln "edit-tui/test/bilingual.rkt: ok")

#lang racket

;;; filetree 插件：
;;;   · sync 扫描目录并写普通 view
;;;   · guarded Enter 只在 sidebar 聚焦时接管
;;;   · Enter 返回 open-file-action，host 打开到 editor panel

(require rackunit
         racket/file
         racket/path
         racket/string
         "../editor/host-api.rkt"
         "../core/command/api.rkt"
         "../plugins/filetree/plugin.rkt"
         "../edit.rkt"
         "fixture.rkt"
         "../features/placement/api.rkt"
         "../host/open.rkt")

(define-values (ed state) (make-test-editor))
(define s0 (state-with-area state (rect 0 0 60 15)))
(define (ft-ps st) (state-plugin-state st 'filetree))

;; 第一帧渲染触发 filetree sync。
(define-values (s1 _c1 _b1) (render-frame ed s0 #f))
(define text (engine-view-text (editor-engine ed) 3))
(check-true (string? text))
(check-true (positive? (string-length text)))
(check-true (string-prefix? text (path->string (current-directory))))

;; 取 filetree 插件 + 它的 guarded Enter。
(define ft-plugin
  (for/first ([p (in-list (editor-plugins ed))]
              #:when (eq? (plugin-id p) 'filetree))
    p))
(check-not-false ft-plugin)

(define-values (status enter-cmd)
  (command-table-lookup (plugin-commands ft-plugin) (list (key 'enter))))
(check-eq? status 'command)
(check-true (guarded-command? enter-cmd))

;; editor 聚焦时 guard 为 false：不抢 Enter。
(check-false ((guarded-command-when-fn enter-cmd) ed s1 (ft-ps s1)))

;; 焦点移到 sidebar 后 guard 为 true。
(define-values (s2 _a2) (editor-focus! ed s1 'left))
(check-equal? (editor-focus-panel-kind s2) 'sidebar)
(check-true ((guarded-command-when-fn enter-cmd) ed s2 (ft-ps s2)))

;; 把 filetree 光标移到第一个文件行。
(define fstate (state-plugin-state s2 'filetree))
(check-true (filetree-state? fstate))
(define rows (filetree-state-rows fstate))
(define file-row
  (for/first ([row (in-list rows)] #:when (eq? (cadr row) 'file)) row))
(check-not-false file-row)
(define file-line
  (for/first ([row (in-list rows)] [i (in-naturals)]
              #:when (eq? (cadr row) 'file))
    i))
(engine-set-view-cursor! (editor-engine ed) 3 file-line #:column 0)

;; 执行插件命令 -> open-file-action。
(define-values (s3 _ps3 actions3) ((guarded-command-run enter-cmd) ed s2 (ft-ps s2)))
(define open-action
  (for/first ([a (in-list actions3)] #:when (open-file-action? a)) a))
(check-not-false open-action)

;; host 解释 action：新文件进入 placement。
(define path (open-file-action-path open-action))
(define-values (s4 _more) (editor-open-file! ed s3 path))
(check-true (editor-placement-active? s4))
(check-equal? (editor-focus-panel-kind s4) 'editor)

;; placement 提交后视图进入 editor panel。
(define-values (s5 _more2) (editor-placement-commit ed s4))
(check-false (editor-placement-active? s5))
(check-equal? (editor-focus-panel-kind s5) 'editor)
(define vid (editor-focus-view-id s5))
(check-not-false vid)
(check-equal? (engine-view-text (editor-engine ed) vid)
              (file->string path))

;; 打开过的文件在文件树里用 filetree-open face（来自 resource opened 集合）。
(define s6 (run-plugin-syncs ed s5))
(check-equal? (engine-view-face-at (editor-engine ed) 3 file-line 0)
              'filetree-open)

;; 再次打开同一路径：聚焦已有 view，不新建 resource / doc。
(define n-before (length (resources-list (state-resources s6))))
(define-values (s7 _more3) (editor-open-file! ed s6 path))
(check-false (editor-placement-active? s7))
(check-equal? (editor-focus-view-id s7) vid)
(check-equal? (length (resources-list (state-resources s7))) n-before)

(displayln "edit-tui/test/filetree.rkt: ok")

#lang racket

;;; edit-tui/test/filetree.rkt —— 文件树面板
;;;
;;; 覆盖：根路径第一行、2 空格缩进、颜色、展开/折叠、打开文件 placement、
;;; 无 editor panel 时自动创建、C-n f / C-n C-n f / C-d。

(require rackunit
         racket/file
         racket/path
         racket/async-channel
         "../command/key.rkt"
         "../command/mouse.rkt"
         (prefix-in app: "../base/event.rkt")
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../base/id.rkt"
         "../base/transition.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/chrome.rkt"
         "../plugins/resource/model.rkt"
         "../plugins/filetree/model.rkt"
         "../effects/engine.rkt"
         "../plugins/filetree/plugin.rkt"
         "../plugins/filetree/scan.rkt"
         "../projection/geometry.rkt"
         "../../core/view/base/rect.rkt"
         (except-in "../chrome/slot.rkt" input-show)
         "../chrome/input.rkt"
         "../bootstrap/defaults.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(define root (build-path (find-system-path 'temp-dir)
                         (format "rebuild-filetree-~a" (random))))
(make-directory root)
(define a-path (build-path root "a.txt"))
(display-to-file "A" a-path #:exists 'truncate)
(define sub-dir (build-path root "sub"))
(make-directory sub-dir)
(define b-path (build-path sub-dir "b.txt"))
(display-to-file "B" b-path #:exists 'truncate)

(define ft-rid (region-id 1))
(define chrome-rid (region-id 2))
(define engine (make-engine))
(define s0 (make-state #:ids (make-id-counter 1 1 3 1)))
(define s1 (install-filetree-panel! engine s0 ft-rid (path->string root)))
(define s2 (install-chrome! engine s1 chrome-rid))
(define ftv (filetree-panel-view s2))
(define lay (make-split 'tb
                        (list (make-leaf ft-rid (flex 1))
                              (make-leaf chrome-rid (fixed 1) #:borders '()))
                        (flex 1)))
(define state
  (state-set-focus
   (state-set-workspace s2
                        (struct-copy workspace (state-workspace s2) [layout lay]))
   ftv))

(define inbox (make-async-channel))
(define (feed eng s . evs)
  (transition-state (process-events default-env eng inbox s evs)))
(define (plain c) (app:key-event (key c)))
(define (ctrl c)  (app:key-event (key c 'ctrl)))
(define (meta c)  (app:key-event (key c 'alt)))
(define (set-line! s line)
    (view-set-selections! (engine-view-object engine ftv)
                        (selections-one (caret (point line 0))))
  s)
(define (lines s) (filetree-lines s dir-entries))
(define (index-of-line s pred)
  (for/or ([l (in-list (lines s))] [i (in-naturals)] #:when (pred l)) i))

;;; ════════════════ 行 / 颜色 / 缩进 ════════════════

;;; ════════════════ C-b 显隐 ════════════════
(define s-hidden (feed engine state (ctrl 'b)))
(check-false (tree-visible? (workspace-layout (state-workspace s-hidden)) ft-rid))
(check-false (state-focus s-hidden))
;; toggle-region! 把隐藏尺寸写回 layout leaf 的 fixed dim
(define hidden-leaf (tree-find (workspace-layout (state-workspace s-hidden)) ft-rid))
(check-true (dim-fixed? (leaf-dim hidden-leaf)))
(define hidden-size (dim-value (leaf-dim hidden-leaf)))
(check-true (>= hidden-size 20))
(define s-shown (feed engine s-hidden (ctrl 'b)))
(check-true (tree-visible? (workspace-layout (state-workspace s-shown)) ft-rid))
(define ft-leaf (tree-find (workspace-layout (state-workspace s-shown)) ft-rid))
(check-true (dim-fixed? (leaf-dim ft-leaf)))
(check-equal? (dim-value (leaf-dim ft-leaf)) hidden-size)

;; 再隐藏仍然使用同一份尺寸
(define s-hidden-again (feed engine s-shown (ctrl 'b)))
(check-false (tree-visible? (workspace-layout (state-workspace s-hidden-again)) ft-rid))
(define hidden-leaf-again (tree-find (workspace-layout (state-workspace s-hidden-again)) ft-rid))
(check-equal? (dim-value (leaf-dim hidden-leaf-again)) hidden-size)
(define s-shown-again (feed engine s-hidden-again (ctrl 'b)))
(check-true (tree-visible? (workspace-layout (state-workspace s-shown-again)) ft-rid))

(define ls0 (lines s-shown-again))
(define root-line (car ls0))
(check-eq? (filetree-line-kind root-line) 'root)
(check-true (string=? (filetree-line-path root-line)
                      (filetree-normalize-path (path->string root))))
(check-true (string-contains? (filetree-line-text root-line) (path->string root)))
(check-eq? (filetree-line-face root-line) 'filetree-root)

(define sub-line (for/or ([l (in-list ls0)]
                          #:when (equal? (filetree-line-path l) (filetree-normalize-path sub-dir)))
                   l))
(check-eq? (filetree-line-kind sub-line) 'dir)
(check-eq? (filetree-line-face sub-line) 'filetree-dir)
(check-true (string-prefix? (filetree-line-text sub-line) "  sub"))

(define a-line (for/or ([l (in-list ls0)]
                        #:when (equal? (filetree-line-path l) (filetree-normalize-path a-path)))
                 l))
(check-eq? (filetree-line-kind a-line) 'file)
(check-eq? (filetree-line-face a-line) 'filetree-file)
(check-true (string-prefix? (filetree-line-text a-line) "  a.txt"))

;;; ════════════════ 折叠 root / 展开 sub ════════════════

(sync-filetree-panel! state engine)
(define s-collapse (feed engine (set-line! state 0) (app:key-event (key 'enter))))
(check-equal? (length (lines s-collapse)) 1)
(define s-expand (feed engine s-collapse (app:key-event (key 'enter))))
(check-equal? (length (lines s-expand)) (length ls0))

(sync-filetree-panel! state engine)
(define sub-idx (index-of-line state (λ (l) (equal? (filetree-line-path l) (filetree-normalize-path sub-dir)))))
(define s-sub (feed engine (set-line! state sub-idx) (app:key-event (key 'enter))))
(define b-line (for/or ([l (in-list (lines s-sub))]
                        #:when (equal? (filetree-line-path l) (filetree-normalize-path b-path)))
                l))
(check-not-false b-line)
(check-true (string-prefix? (filetree-line-text b-line) "    b.txt"))
(sync-filetree-panel! s-sub engine)

;;; ════════════════ 打开文件：无 editor panel -> 自动创建 ════════════════

(define a-idx (index-of-line s-sub (λ (l) (equal? (filetree-line-path l) (filetree-normalize-path a-path)))))
(define s-open (feed engine (set-line! s-sub a-idx) (app:key-event (key 'enter))))
(define open-focus (state-focus s-open))
(check-not-false open-focus)
(check-not-equal? open-focus ftv)
(define open-doc (workspace-doc-of-view (state-workspace s-open) open-focus))
(check-not-false open-doc)
(check-equal? (doc-meta-path (workspace-doc (state-workspace s-open) open-doc))
              (filetree-normalize-path a-path))
(check-true (engine-view-exists? engine open-focus))
(check-eq? (for/first ([l (in-list (lines s-open))]
                       #:when (equal? (filetree-line-path l) (filetree-normalize-path a-path)))
             (filetree-line-face l))
          'filetree-open)

;; 嵌套在 lr 里的 filetree 也能 C-b 显隐（parent-axis 递归）
(define s-hidden-nested (feed engine s-open (ctrl 'b)))
(check-false (tree-visible? (workspace-layout (state-workspace s-hidden-nested)) ft-rid))
(define s-shown-nested (feed engine s-hidden-nested (ctrl 'b)))
(check-true (tree-visible? (workspace-layout (state-workspace s-shown-nested)) ft-rid))

;;; ════════════════ 打开 b：已有 editor -> placement，用户选 panel ════════════════

(define s-open-ft (feed engine s-open (meta 'left)))
(check-equal? (state-focus s-open-ft) ftv)
(sync-filetree-panel! s-open-ft engine)
(define b-idx (index-of-line s-open-ft (λ (l) (equal? (filetree-line-path l) (filetree-normalize-path b-path)))))
(define s-pending (feed engine (set-line! s-open-ft b-idx) (app:key-event (key 'enter))))
(check-not-false (workspace-placement (state-workspace s-pending)))
(define pending-vid (workspace-placement (state-workspace s-pending)))
(check-false (workspace-view-attached? (state-workspace s-pending) pending-vid))
;; 聚焦目标 editor panel
(define s-target (feed engine s-pending (meta 'right)))
(check-equal? (state-focus s-target) open-focus)
(define s-placed (feed engine s-target (ctrl 'x)))
(define s-placed* (feed engine s-placed (ctrl 'p)))
(check-equal? (state-focus s-placed*) pending-vid)
(check-true (workspace-view-attached? (state-workspace s-placed*) pending-vid))
(check-false (workspace-view-attached? (state-workspace s-placed*) open-focus))

;;; ════════════════ C-n f 创建文件 ════════════════

(define s-ft (feed engine s-placed* (meta 'left)))
(check-equal? (state-focus s-ft) ftv)
(sync-filetree-panel! s-ft engine)
(define s-cf1 (feed engine (set-line! s-ft 0) (ctrl 'n)))
(define s-cf2 (feed engine s-cf1 (app:key-event (key 'f))))
(check-true (input-active? s-cf2))
(define new-file (build-path root "new.txt"))
(define s-cf3 (for/fold ([s s-cf2]) ([c (in-string "new.txt")]) (feed engine s (plain c))))
(define s-cf4 (feed engine s-cf3 (app:key-event (key 'enter))))
(check-true (file-exists? new-file))
(sync-filetree-panel! s-cf4 engine)
(check-not-false (for/first ([l (in-list (lines s-cf4))]
                             #:when (equal? (filetree-line-path l) (filetree-normalize-path new-file)))
                   #t))

;;; ════════════════ C-n C-n f 创建文件夹 ════════════════

(define s-cd1 (feed engine s-cf4 (ctrl 'n)))
(define s-cd2 (feed engine s-cd1 (ctrl 'n)))
(define s-cd3 (feed engine s-cd2 (app:key-event (key 'f))))
(check-true (input-active? s-cd3))
(define new-dir (build-path root "newdir"))
(define s-cd4 (for/fold ([s s-cd3]) ([c (in-string "newdir")]) (feed engine s (plain c))))
(define s-cd5 (feed engine s-cd4 (app:key-event (key 'enter))))
(check-true (directory-exists? new-dir))

;;; ════════════════ C-d 删除文件 ════════════════

(sync-filetree-panel! s-cd5 engine)
(define new-idx (index-of-line s-cd5 (λ (l) (equal? (filetree-line-path l) (filetree-normalize-path new-file)))))
(define s-del-prompt (feed engine (set-line! s-cd5 new-idx) (ctrl 'd)))
(check-true (input-active? s-del-prompt))
;; 输入占用时 C-b 不改变文件树显隐
(define s-del-prompt-b (feed engine s-del-prompt (ctrl 'b)))
(check-true (tree-visible? (workspace-layout (state-workspace s-del-prompt-b)) ft-rid))
(check-true (input-active? s-del-prompt-b))
;; n：取消，文件仍在
(define s-del-n (feed engine s-del-prompt-b (plain #\n)))
(define s-del-n* (feed engine s-del-n (app:key-event (key 'enter))))
(check-true (file-exists? new-file))
(check-false (input-active? s-del-n*))
;; 取消会留一条 "cancelled: …"，但不能常驻：下一次按键就清掉
(check-true (string-contains? (chrome-message (state-chrome s-del-n*)) "cancelled"))
;; 方向键只发 nav effect、不产生消息 -> 状态栏恢复干净
(define s-del-n-next (feed engine s-del-n* (app:key-event (key 'down))))
(check-equal? (chrome-message (state-chrome s-del-n-next)) "")
;; y：确认删除
(sync-filetree-panel! s-del-n* engine)
(define s-del2-prompt (feed engine (set-line! s-del-n* new-idx) (ctrl 'd)))
(define s-del2-y (feed engine s-del2-prompt (plain #\y)))
(define s-del (feed engine s-del2-y (app:key-event (key 'enter))))
(check-false (file-exists? new-file))
(sync-filetree-panel! s-del engine)
(check-false (for/first ([l (in-list (lines s-del))]
                         #:when (equal? (filetree-line-path l) (filetree-normalize-path new-file)))
               #t))


;;; ════════════════ 左侧全高布局：记录/恢复的是宽度 ════════════════

(define e2 (make-engine))
(define fr2 (region-id 1))
(define er2 (region-id 2))
(define t0 (make-state #:ids (make-id-counter 1 1 3 1)))
(define t1 (install-filetree-panel! e2 t0 fr2 (path->string root)))
(define t2 (state-workspace* t1 (λ (ws) (workspace-add-region ws er2 (region er2 '() #f 'editor)))))
(define lr-lay
  (make-split 'lr
              (list (make-leaf fr2 (fixed 28) #:borders '(right))
                    (make-leaf er2 (flex 1)))
              (flex 1)))
(define t3 (state-set-workspace t2 (struct-copy workspace (state-workspace t2) [layout lr-lay])))
(define t4 (state-set-focus t3 (filetree-panel-view t3)))
(define t-area (rect 0 0 80 24))
(define-values (t-rps _t-cuts) (geometry-solve (workspace-layout (state-workspace t4)) t-area))
(define t-rp (for/first ([p (in-list t-rps)] #:when (equal? (region-panel-region p) fr2)) p))
(define width-before (rect-w (region-panel-content t-rp)))
(define t-hidden (feed e2 t4 (ctrl 'b)))
(define t-hidden-leaf (tree-find (workspace-layout (state-workspace t-hidden)) fr2))
(check-true (dim-fixed? (leaf-dim t-hidden-leaf)))
(check-equal? (dim-value (leaf-dim t-hidden-leaf)) width-before)
(define t-shown (feed e2 t-hidden (ctrl 'b)))
(define-values (t-rps2 _t-cuts2) (geometry-solve (workspace-layout (state-workspace t-shown)) t-area))
(define t-rp2 (for/first ([p (in-list t-rps2)] #:when (equal? (region-panel-region p) fr2)) p))
(check-equal? (rect-w (region-panel-content t-rp2)) width-before)

(delete-directory/files root)
(displayln "edit-tui filetree: ok")

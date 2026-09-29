#lang racket

;;; command.rkt —— 命令层：intent → session（**唯一写口**）
;;;
;;; 输入分发的终点。集中所有行为与策略，按域分组：
;;;   全局      app/quit / focus/toggle
;;;   编辑器    editor/*    输入 / 编辑 / 导航 / 撤销 / 多光标 / 高亮
;;;   文件树    tree/*      打开 / 新建 / 删除（含根禁删、目录确认）
;;;   提示态    prompt/*    输入 / 确认 / 取消（瞬时模态，见 bindings.rkt）
;;;   文件/鼠标 file/open / input/*
;;;
;;; 关键设计：
;;;   · run : session × intent → session，永远返回**新 session**，不就地改。
;;;   · 命令可 enqueue 后续意图（tree 激活 → file/open），由 command-step 排空。
;;;   · 提示输入不存闭包：prompt/start 前把「待确认意图」放进 session.pending，
;;;     确认时按 tag 决定「并入缓冲」还是「要求 y」，再入队执行。
;;;   · 组件（tree/status）保持纯：命令层只调用它们的纯函数 + 读写 host pane 状态。
;;;
;;; 「哪个键派发成哪个 intent」在 bindings.rkt；本模块不认任何键。

(provide run-intent command-step)

(require racket/string
         "../core/editor.rkt"
         "../core/text/base/selection.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/range.rkt"
         "intent.rkt" "session.rkt" "host.rkt" "tree.rkt" "status.rkt" "workspace.rkt" "fs.rkt"
         "bindings.rkt")

;;; ============================================================================
;;; 小工具
;;; ============================================================================

(define (host-of s) (session-host s))
(define (editor-of s) (host-editor (host-of s)))
(define (focus-vid s) (session-focus-vid s))

;; 取第一个返回值（编辑命令有的返回 (values ed changes)，有的只返回 ed）。
(define (first-value thunk) (call-with-values thunk (lambda (v . _) v)))

;; 状态栏消息。
(define (set-msg s m)
  (define sid (session-status-id s))
  (if sid
      (session-set-pane-state s sid (status-set-msg (session-pane-state s sid) m))
      s))

;; 编辑类命令（插 / 删 / 粘）：无变化 = 被只读挡住 → 提示。
(define (editor-edit! s f)
  (define h (host-of s))
  (define v (focus-vid s))
  (define ed (host-editor h))
  (define ed* (first-value (lambda () (f ed v))))
  (set-msg (session-set-editor s ed*) (if (eq? ed* ed) "只读：已拒绝" "")))

;; 非编辑命令（导航 / 撤销 / 模式 / 高亮）：无变化也清消息。
(define (editor-do! s f)
  (define h (host-of s))
  (define v (focus-vid s))
  (define ed (host-editor h))
  (define ed* (first-value (lambda () (f ed v))))
  (set-msg (session-set-editor s ed*) ""))

(define (page-size s) (max 1 (sub1 (editor-view-height (editor-of s) (focus-vid s)))))

;;; ============================================================================
;;; 焦点
;;; ============================================================================

(define (focus-toggle! s)
  (define h (host-of s))
  (define tid (session-tree-id s))
  (define eid (session-editor-id s))
  (session-set-focus s (if (equal? (host-focus-id h) tid) eid tid)))

;;; ============================================================================
;;; 文档 / 编辑格（单格替换）
;;; ============================================================================

;; 给 did 建视图并注册为编辑格 pane（不动旧的）→ 新 session。顺带登记 editor-keymap。
(define (install-editor! s did)
  (define h (host-of s))
  (define ch (max 1 (sub1 (host-rows h))))
  (define-values (ed2 new-vid) (editor-add-view (host-editor h) did 40 ch 'free #f #:line-numbers? #t))
  (define-values (h1 new-eid) (host-adopt-view (struct-copy host h [editor ed2]) new-vid))
  (define s1 (session-set-mode (session-set-editor-id (session-set-host s h1) new-eid) did editor-keymap))
  (define h2 (host-set-layout (host-of s1) (session-layout s1)))
  (session-set-focus (session-set-host s1 h2) new-eid))

;; 关旧视图再装新 did（打开文件用）
(define (swap-editor! s did)
  (define h (host-of s))
  (define eid (session-editor-id s))
  (define ed (editor-close-view (host-editor h) (host-pane-vid h eid)))
  (install-editor! (session-set-host s (struct-copy host h [editor ed])) did))

;; 把 workspace 的「已打开」集合同步给树
(define (sync-tree-open! s)
  (define tid (session-tree-id s))
  (session-set-pane-state s tid
    (tree-set-open-paths (session-pane-state s tid) (ws-open-paths (session-ws s)))))

(define (open-path! s path)
  (define h (host-of s))
  (define eid (session-editor-id s))
  (define old-vid (host-pane-vid h eid))
  (define-values (ws* ed1 did) (ws-open (session-ws s) (host-editor h) path))
  (define s1 (session-set-ws s ws*))
  (cond
    ;; 已经是这个文档 → 只把焦点还回编辑格
    [(= did (editor-view-document-id ed1 old-vid))
     (session-set-focus (session-set-editor s1 ed1) eid)]
    [else
     (sync-tree-open! (swap-editor! (session-set-editor s1 ed1) did))]))

;; 关掉某个文档：workspace 去除 + 若编辑格正显示它则换空 scratch。
;; 注意 ws-close → editor-close-document 会连带删掉该文档所有视图，
;; 所以若编辑格正显示它，必须先摘掉编辑格 pane，免得 host 指向消失的 view。
(define (close-doc! s did)
  (define h (host-of s))
  (define eid (session-editor-id s))
  (define cur-did (editor-view-document-id (host-editor h) (host-pane-vid h eid)))
  (define shown? (= did cur-did))
  (define h0 (if shown? (host-remove-pane h eid) h))
  (define-values (ws* ed1) (ws-close (session-ws s) (host-editor h0) did))
  (define s1 (session-set-ws (session-set-host s h0) ws*))
  (cond
    [shown?
     (define-values (ed2 new-did) (editor-add-document ed1 "" "*scratch*"))
     (install-editor! (session-set-host s1 (struct-copy host (host-of s1) [editor ed2])) new-did)]
    [else (session-set-editor s1 ed1)]))

;; 删除的文件若正被打开：关掉它。
(define (close-deleted! s path)
  (define did (ws-did (session-ws s) path))
  (if did (close-doc! s did) s))

;; 编辑格当前显示的文档 id（可能 #f）。
(define (editor-did s)
  (editor-view-document-id (editor-of s) (session-pane-vid s (session-editor-id s))))

;;; ============================================================================
;;; 文件树：光标行 / pane 状态
;;; ============================================================================

(define (tree-vid s) (session-pane-vid s (session-tree-id s)))
(define (tree-st s) (session-pane-state s (session-tree-id s)))
(define (tree-line s) (editor-view-point-line (editor-of s) (tree-vid s)))
(define (cur-entry s) (tree-line-entry (tree-st s) (tree-line s)))

;; 把树光标放到第 line 行（core 会 ensure → 自动滚动）。
(define (tree-set-line! s line)
  (session-set-editor s (editor-view-set-point (editor-of s) (tree-vid s) (point line 0))))

(define (tree-line-of st path)
  (for/first ([v (in-list (tree-visible st))] [i (in-naturals)]
              #:when (equal? (entry-path (cdr v)) path))
    i))

(define (tree-set-state s st) (session-set-pane-state s (session-tree-id s) st))

;; 立刻把树的最新 state 投影成文档并写回视图（不必等下一帧 host-frame）。
;; 否则 tree-create/delete 后立刻 set-point 会对着旧文档 clamp，落错行。
(define (tree-project! s)
  (session-set-host s (host-sync-pane (session-host s) (session-tree-id s))))

;;; ============================================================================
;;; 状态栏提示（瞬时模态 + 待确认意图）
;;; ============================================================================

;; 命名提示：确认时把缓冲当名字，并入 on-yes 的 payload 末尾。
(define (pending-name on-yes) (pending 'name on-yes #f))
;; 是否确认：y → on-yes；n → on-no（#f = 忽略）。
(define (pending-yn yes [no #f]) (pending 'yesno yes no))

(define (prompt-start! s label default pending)
  (define sid (session-status-id s))
  (define s1 (session-set-pane-state s sid
               (status-start-prompt (session-pane-state s sid) label default)))
  (session-set-pending (session-push-mode s1 prompt-keymap) pending))

(define (prompt-clear s)
  (define sid (session-status-id s))
  (session-set-pane-state s sid (status-clear-prompt (session-pane-state s sid))))

(define (prompt-buffer s) (status-input-buffer (session-pane-state s (session-status-id s))))

;;; ============================================================================
;;; 多光标 / 单词 / 搜索（纯助手，原在 tui.rkt）
;;; ============================================================================

(define (vid-lines e v) (string-split (editor-view-string e v) "\n" #:trim? #f))
(define (word-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))

(define (word-range line col)
  (define n (string-length line))
  (define (at i) (and (< i n) (word-char? (string-ref line i))))
  (define c (cond [(and (< col n) (at col)) col]
                  [(and (> col 0) (at (sub1 col))) (sub1 col)]
                  [else #f]))
  (cond
    [(not c) (values (min col n) (min col n))]
    [else
     (values (let loop ([i c]) (if (and (> i 0) (at (sub1 i))) (loop (sub1 i)) i))
             (let loop ([i c]) (if (at i) (loop (add1 i)) i)))]))

(define (line-matches line needle)
  (for/list ([m (in-list (regexp-match-positions* (regexp (regexp-quote needle)) line))])
    (car m)))

(define (selection-text e v s)
  (define-values (a b) (selection-range s))
  (and (= (point-line a) (point-line b))
       (substring (list-ref (vid-lines e v) (point-line a)) (point-col a) (point-col b))))

(define (selection-ranges ss)
  (for/list ([s (in-list (selections-items ss))])
    (call-with-values (lambda () (selection-range s)) cons)))

(define (selections-add-primary ss sel)
  (selections-dedupe
   (selections-set-primary (selections-add ss (list sel)) (selections-count ss))))

(define (next-match e v needle after ss)
  (define n (string-length needle))
  (define ranges (selection-ranges ss))
  (define (overlaps? a b)
    (for/or ([r (in-list ranges)]) (and (point<? (car r) b) (point<? a (cdr r)))))
  (define matches
    (append*
     (for/list ([line (in-list (vid-lines e v))] [li (in-naturals)])
       (for/list ([start (in-list (line-matches line needle))])
         (cons (point li start) (point li (+ start n)))))))
  (define ordered (append (filter (lambda (m) (point<? after (car m))) matches)
                          (filter (lambda (m) (point<=? (car m) after)) matches)))
  (for/first ([m (in-list ordered)] #:unless (overlaps? (car m) (cdr m))) m))

;; C-d：无选区 → 选当前词；有选区 → 选下一个相同文本（多光标）
(define (multi-add-next e v)
  (define ss (editor-view-selections e v))
  (define prim (selections-primary ss))
  (define-values (a b) (selection-range prim))
  (cond
    [(point=? a b)
     (define line (point-line a))
     (define-values (ws we) (word-range (list-ref (vid-lines e v) line) (point-col a)))
     (if (= ws we)
         e
         (editor-view-set-selections e v (selections-one (selection (point line ws) (point line we)))))]
    [else
     (define needle (selection-text e v prim))
     (cond
       [(or (not needle) (string=? needle "")) e]
       [else
        (define m (next-match e v needle b ss))
        (cond [(not m) e]
              [else (editor-view-set-selections e v
                      (selections-add-primary ss (selection (car m) (cdr m))))])])]))

;; C-m：把所有相同匹配都加上
(define (multi-add-all e v)
  (define ss (editor-view-selections e v))
  (define prim (selections-primary ss))
  (define-values (a b) (selection-range prim))
  (cond
    [(point=? a b)
     (define ed* (multi-add-next e v))
     (if (eq? ed* e) e (multi-add-all ed* v))]
    [else
     (define needle (selection-text e v prim))
     (cond
       [(or (not needle) (string=? needle "")) e]
       [else
        (define n (string-length needle))
        (define all
          (append*
           (for/list ([line (in-list (vid-lines e v))] [li (in-naturals)])
             (for/list ([start (in-list (line-matches line needle))])
               (selection (point li start) (point li (+ start n)))))))
        (cond
          [(null? all) e]
          [else (editor-view-set-selections e v
                  (selections-normalize
                   (selections-set-primary-value (selections all 0) prim)))])])]))

;; Alt/Ctrl+Shift+方向：在上/下一行同位加光标
(define (multi-add-line e v delta)
  (define ss (editor-view-selections e v))
  (define p (selection-point (selections-primary ss)))
  (define lines (vid-lines e v))
  (define l (+ (point-line p) delta))
  (cond
    [(or (< l 0) (>= l (length lines))) e]
    [else
     (define col (min (point-col p) (string-length (list-ref lines l))))
     (editor-view-set-selections e v (selections-add-primary ss (caret (point l col))))]))

;;; ============================================================================
;;; 鼠标 / 输入定位
;;; ============================================================================

;; payload = (vid local-row local-col)
(define (input-click! s vid r c)
  (define s1 (session-set-focus-vid s vid))
  (define ed (editor-of s1))
  (define-values (line col) (editor-view-screen-pos->point ed vid r c))
  (cond
    [(not line) (set-msg s1 "")]
    [else (set-msg (session-set-editor s1 (editor-view-set-point ed vid (point line col))) "")]))

(define (input-add-cursor! s vid r c)
  (define s1 (session-set-focus-vid s vid))
  (define ed (editor-of s1))
  (define-values (line col) (editor-view-screen-pos->point ed vid r c))
  (cond
    [(not line) s1]
    [else
     (define ss* (selections-add-primary (editor-view-selections ed vid) (caret (point line col))))
     (set-msg (session-set-editor s1 (editor-view-set-selections ed vid ss*)) "加光标")]))

;;; ============================================================================
;;; 主分派：intent → session
;;; ============================================================================

(define (run-intent s it)
  (define p (intent-payload it))
  (case (intent-tag it)

    ;; ---------- 全局 ----------
    [(app/quit)    (session-set-quit s #t)]
    [(focus/toggle) (focus-toggle! s)]

    ;; ---------- 编辑器：输入 / 编辑 ----------
    [(editor/insert)
     (define text (car p))
     (define tag (if (null? (cdr p)) 'typing (cadr p)))
     (editor-edit! s (lambda (e v) (editor-view-insert e v text tag)))]
    [(editor/backspace) (editor-edit! s (lambda (e v) (editor-view-backspace e v 'backspace)))]
    [(editor/delete)    (editor-edit! s (lambda (e v) (editor-view-delete e v 'delete)))]
    [(editor/paste)     (editor-edit! s (lambda (e v) (editor-view-paste e v)))]

    ;; ---------- 编辑器：导航 ----------
    [(editor/left)  (editor-do! s (lambda (e v) (editor-view-left e v (extend? p))))]
    [(editor/right) (editor-do! s (lambda (e v) (editor-view-right e v (extend? p))))]
    [(editor/up)    (editor-do! s (lambda (e v) (editor-view-up e v (extend? p))))]
    [(editor/down)  (editor-do! s (lambda (e v) (editor-view-down e v (extend? p))))]
    [(editor/home)  (editor-do! s (lambda (e v) (editor-view-home e v (extend? p))))]
    [(editor/end)   (editor-do! s (lambda (e v) (editor-view-end e v (extend? p))))]
    [(editor/pageup)   (editor-do! s (lambda (e v) (editor-view-scroll e v (- (page-size s)))))]
    [(editor/pagedown) (editor-do! s (lambda (e v) (editor-view-scroll e v (page-size s))))]
    [(editor/scroll)   (editor-do! s (lambda (e v) (editor-view-scroll e v (car p))))]
    [(editor/collapse)
     (editor-do! s (lambda (e v)
                     (editor-view-set-selections e v
                       (selections-one (selections-primary (editor-view-selections e v))))))]

    ;; ---------- 编辑器：撤销 / 复制 / 模式 ----------
    [(editor/undo) (editor-do! s (lambda (e v) (editor-view-undo e v)))]
    [(editor/redo) (editor-do! s (lambda (e v) (editor-view-redo e v)))]
    [(editor/copy) (editor-do! s (lambda (e v) (editor-view-copy e v)))]
    [(editor/toggle-wrap)
     (editor-do! s (lambda (e v)
                     (editor-view-set-mode e v (if (eq? (editor-view-mode e v) 'clip) 'wrap 'clip))))]
    [(editor/toggle-line-numbers)
     (editor-do! s (lambda (e v) (editor-view-toggle-line-numbers e v)))]

    ;; ---------- 编辑器：多光标 ----------
    [(editor/add-cursor-next) (editor-do! s multi-add-next)]
    [(editor/add-cursor-all)  (editor-do! s multi-add-all)]
    [(editor/add-cursor-line) (editor-do! s (lambda (e v) (multi-add-line e v (car p))))]

    ;; ---------- 编辑器：高亮 / 只读（作者态，不记步） ----------
    [(editor/highlight) (editor-do! s (lambda (e v) (editor-view-highlight e v (car p))))]
    [(editor/readonly)  (editor-do! s (lambda (e v) (editor-view-readonly e v (car p))))]

    ;; ---------- 文件树 ----------
    [(tree/activate)
     (define-values (st* intent) (tree-activate (tree-st s) (cur-entry s)))
     (define s1 (tree-project! (tree-set-state s st*)))
     (cond [(not intent) s1]
           [else (session-enqueue s1 (make-intent 'file/open (list (cadr intent)) (tree-vid s)))])]

    [(tree/new-file)
     (prompt-start! s "新建文件: " "untitled"
                    (pending-name (make-intent 'tree/create-ask
                                               (list 'file (tree-target-dir (tree-st s) (cur-entry s)))
                                               (tree-vid s))))]

    [(tree/new-dir)
     (prompt-start! s "新建文件夹: " "new-folder"
                    (pending-name (make-intent 'tree/create-ask
                                               (list 'dir (tree-target-dir (tree-st s) (cur-entry s)))
                                               (tree-vid s))))]

    [(tree/delete)
     (define e (cur-entry s))
     (cond
       [(not e) s]
       ;; 根目录禁删
       [(equal? (entry-path e) (entry-path (tree-root (tree-st s)))) (set-msg s "根目录不能删除")]
       ;; 文件 / 目录都要确认（输入 y）。写入类操作（新建）在下一个提示里再确认。
       [else
        (prompt-start! s
                       (if (entry-dir? e)
                           (format "删除目录 ~a 及其全部内容？输入 y 回车确认 " (entry-name e))
                           (format "删除文件 ~a？输入 y 回车确认 " (entry-name e)))
                       ""
                       (pending-yn (make-intent 'tree/delete* (list (entry-path e)) (tree-vid s))))])]

    ;; 名字输完后，再确认一次「写入」
    [(tree/create-ask)
     (define name (caddr p))
     (prompt-start! s (format "确认写入 ~a？(y/n) " name) ""
                    (pending-yn (make-intent 'tree/create (list (car p) (cadr p) name) (tree-vid s))))]

    [(tree/create)
     (define-values (kind dir name) (values (car p) (cadr p) (caddr p)))
     (define-values (st* path) (tree-create-at (tree-st s) dir kind name))
     (define s1 (tree-project! (tree-set-state s st*)))
     (define line (tree-line-of (tree-st s1) path))
     (if line (tree-set-line! s1 line) s1)]

    [(tree/delete*) (tree-do-delete-path! s (car p))]
    [(tree/ignore) s]

    ;; ---------- 提示态 ----------
    [(prompt/insert)
     (define sid (session-status-id s))
     (define st (session-pane-state s sid))
     (session-set-pane-state s sid
       (status-set-buffer st (string-append (status-input-buffer st) (car p))))]

    [(prompt/backspace)
     (define sid (session-status-id s))
     (define st (session-pane-state s sid))
     (define b (status-input-buffer st))
     (if (> (string-length b) 0)
         (session-set-pane-state s sid (status-set-buffer st (substring b 0 (sub1 (string-length b)))))
         s)]

    [(prompt/confirm)
     (define buf (prompt-buffer s))
     (define pnd (session-pending s))
     (define s1 (session-set-pending (session-pop-mode (prompt-clear s)) #f))
     (cond
       [(not pnd) s1]
       ;; 命名类：把缓冲当名字，并入 on-yes 的 payload
       [(eq? 'name (pending-kind pnd))
        (if (string=? buf "")
            s1
            (session-enqueue s1 (intent (intent-tag (pending-on-yes pnd))
                                        (append (intent-payload (pending-on-yes pnd)) (list buf))
                                        (intent-origin (pending-on-yes pnd)))))]
       ;; 是否确认：y → on-yes；n → on-no
       [else
        (cond [(string-ci=? buf "y") (session-enqueue s1 (pending-on-yes pnd))]
              [(string-ci=? buf "n") (if (pending-on-no pnd) (session-enqueue s1 (pending-on-no pnd)) s1)]
              [else s1])])]

    [(prompt/cancel) (session-set-pending (session-pop-mode (prompt-clear s)) #f)]

    ;; ---------- 文件：保存 / 关闭 / 鼠标 / 状态 ----------
    [(file/save)
     (define did (editor-did s))
     (define-values (ws* path) (if did (ws-save (session-ws s) (editor-of s) did) (values (session-ws s) #f)))
     (set-msg (session-set-ws s ws*) (if path (format "已写入 ~a" path) "无路径，未写入"))]

    ;; C-w：脏文档先问是否写入；不写入再问是否确认关闭。
    [(file/close)
     (define did (editor-did s))
     (cond
       [(not did) s]
       [(ws-dirty? (session-ws s) (editor-of s) did)
        (prompt-start! s (format "~a 已修改，写入？(y/n) " (ws-path (session-ws s) did)) ""
                       (pending-yn (make-intent 'file/save-close (list did))
                                   (make-intent 'file/ask-close (list did))))]
       [else (close-doc! s did)])]

    [(file/save-close)
     (define did (car p))
     (define-values (ws* _path) (ws-save (session-ws s) (editor-of s) did))
     (close-doc! (session-set-ws s ws*) did)]

    [(file/ask-close)
     (define did (car p))
     (prompt-start! s "不写入，确认关闭？(y/n) " ""
                    (pending-yn (make-intent 'file/close-do (list did))))]

    [(file/close-do) (close-doc! s (car p))]

    [(file/open)   (open-path! s (car p))]
    [(input/click) (input-click! s (car p) (cadr p) (caddr p))]
    [(input/add-cursor) (input-add-cursor! s (car p) (cadr p) (caddr p))]
    [(input/scroll) (editor-do! s (lambda (e v) (editor-view-scroll e v (car p))))]
    [(status/msg)  (set-msg s (car p))]

    [else s]))

;; 删除 + 光标落位 + 关掉被删文档。path 已定，不再回头取 entry。
(define (tree-do-delete-path! s path)
  (define line (tree-line s))
  (define-values (st* path*) (tree-delete-path (tree-st s) path))
  (define s1 (tree-project! (tree-set-state s st*)))
  (define n (length (tree-visible (tree-st s1))))
  (define s2 (if (> n 0) (tree-set-line! s1 (min line (sub1 n))) s1))
  (if path* (close-deleted! s2 path*) s2))

;; payload 里第一个参数是不是「扩选」。
(define (extend? p) (and (pair? p) (car p)))

;;; ---------- 排空意图队列 ----------

;; run 可能 enqueue 后续意图（如 tree/activate → file/open），一直处理到队列空。
(define (command-step s)
  (define-values (s1 it) (session-pop-intent s))
  (if it (command-step (run-intent s1 it)) s1))


;;; ---------- 测试（不依赖终端：直接喂 intent，看 session） ----------

(module+ test
  (require rackunit
           "../core/text/document.rkt"
           "../core/text/base/point.rkt"
           "fs.rkt" "host.rkt" "dispatch.rkt")

  (define dir (make-temporary-file "cmddir-~a" 'directory))
  (define tmp (build-path dir "a.txt"))
  (display-to-file "FILE\nsecond\n" tmp #:exists 'replace)

  ;; ---------- 组装一个最小 session（等价于 tui setup 的核心） ----------
  (define ch 9)
  (define ed0 (editor-open "" 40 ch #:line-numbers? #t))
  (define h0 (host-open ed0 10 80))
  (define-values (h1 eid) (host-adopt-view h0 0))
  (define-values (h2 tid) (host-add-document h1 "" 30 ch "*tree*"
                                             #:history? #f #:sync tree-sync
                                             #:state (tree-open dir (fs-real))))
  (define-values (h3 sid) (host-add-document h2 "" 80 1 "*status*"
                                             #:history? #f #:sync status-sync
                                             #:state (status "" #f)))
  (define (did-of s id) (editor-view-document-id (host-editor (session-host s)) (session-pane-vid s id)))
  (define s0 (session-set-focus
              (session-set-ids (session-open h3 (ws-empty) global-keymap) tid sid eid)
              eid))
  (define s-raw (session-set-mode (session-set-mode s0 (did-of s0 tid) tree-keymap)
                                 (did-of s0 eid) editor-keymap))

  ;; ---------- 助手 ----------
  (define (ed* s) (host-editor (session-host s)))
  (define (evid s) (session-pane-vid s (session-editor-id s)))
  (define (tv s) (session-pane-vid s (session-tree-id s)))
  (define (tst s) (session-pane-state s (session-tree-id s)))
  ;; 测试里不跑 host-frame：手动跑 tree-sync 并把生成的文档装回视图。
  (define (tree-sync! s)
    (define-values (doc st*) (tree-sync #f (tst s)))
    (define s1 (session-set-editor s (editor-view-assign (ed* s) (tv s) doc)))
    (session-set-pane-state s1 (session-tree-id s1) st*))
  (define (fire s tag payload origin)
    (tree-sync! (command-step (session-enqueue s (make-intent tag payload origin)))))
  (define (cur-entry s) (tree-line-entry (tst s) (editor-view-point-line (ed* s) (tv s))))
  (define (line-of s path)
    (for/first ([v (in-list (tree-visible (tst s)))] [i (in-naturals)]
                #:when (equal? (entry-path (cdr v)) path)) i))
  (define (set-tree! s path)
    (session-set-editor s (editor-view-set-point (ed* s) (tv s) (point (line-of s path) 0))))
  (define (editor-did* s) (editor-view-document-id (ed* s) (evid s)))

  (define s1 (tree-sync! s-raw))

  ;; 编辑：插入 / 撤销
  (define s2 (fire s1 'editor/insert (list "abc") (evid s1)))
  (check-equal? (editor-view-string (ed* s2) (evid s2)) "abc")
  (define s2u (fire s2 'editor/undo '() (evid s2)))
  (check-equal? (editor-view-string (ed* s2u) (evid s2u)) "")

  ;; 继续后面的流程，从插入后的状态起
  (define s2b (fire s2u 'editor/insert (list "X") (evid s2u)))
  (check-equal? (substring (editor-view-string (ed* s2b) (evid s2b)) 0 1) "X")

  ;; 树：光标放到 a.txt → 激活 → 打开文件
  (define s5 (set-tree! (session-set-focus s2b tid) tmp))
  (define s6 (fire s5 'tree/activate '() (tv s5)))
  (check-true (ws-open? (session-ws s6) tmp))
  (check-equal? (editor-view-string (ed* s6) (evid s6)) "FILE\nsecond\n")

  ;; 新建文件：n → 默认名 untitled → 回车（确认名字）→ 确认写入 y → 回车
  (define s7 (set-tree! (session-set-focus s6 tid) dir))
  (define s8 (fire s7 'tree/new-file '() (tv s7)))
  (check-true (session-mode-active? s8))
  (check-equal? (status-input-buffer (session-pane-state s8 sid)) "untitled")
  (define s9 (fire s8 'prompt/confirm '() (tv s8)))            ; 名字确认 → 写入确认
  (check-true (session-mode-active? s9))
  (define s9y (fire s9 'prompt/insert (list "y") (tv s9)))
  (define s10 (fire s9y 'prompt/confirm '() (tv s9y)))
  (check-false (session-mode-active? s10))
  (define made (build-path dir "untitled"))
  (check-true (file-exists? made))
  (check-equal? (path->string (entry-path (cur-entry s10))) (path->string made))

  ;; 根目录禁删
  (define s11 (set-tree! (session-set-focus s10 tid) dir))
  (define s12 (fire s11 'tree/delete '() (tv s11)))
  (check-true (directory-exists? dir))
  (check-equal? (status-msg (session-pane-state s12 sid)) "根目录不能删除")
  (check-false (session-mode-active? s12))

  ;; 删文件：也要 y 确认
  (define s13 (set-tree! (session-set-focus s12 tid) made))
  (define s13a (fire s13 'tree/delete '() (tv s13)))
  (check-true (session-mode-active? s13a))
  (check-true (file-exists? made))                              ; 还没删
  (define s13b (fire s13a 'prompt/insert (list "y") (tv s13a)))
  (define s14 (fire s13b 'prompt/confirm '() (tv s13b)))
  (check-false (file-exists? made))

  ;; 新建目录：名字 → 确认写入 y → 创建
  (define s15 (set-tree! (session-set-focus s14 tid) dir))
  (define s16 (fire s15 'tree/new-dir '() (tv s15)))
  (define s17 (fire s16 'prompt/confirm '() (tv s16)))          ; 名字确认
  (define s17y (fire s17 'prompt/insert (list "y") (tv s17)))
  (define s18 (fire s17y 'prompt/confirm '() (tv s17y)))
  (define sub (build-path dir "new-folder"))
  (check-true (directory-exists? sub))
  (check-equal? (path->string (entry-path (cur-entry s18))) (path->string sub))

  ;; 删目录：Esc 取消 → 还在
  (define s19 (fire s18 'tree/delete '() (tv s18)))
  (check-true (session-mode-active? s19))
  (define s20 (fire s19 'prompt/cancel '() (tv s19)))
  (check-true (directory-exists? sub))

  ;; 删目录：y 确认 → 真删
  (define s21 (fire s20 'tree/delete '() (tv s20)))
  (define s22 (fire s21 'prompt/insert (list "y") (tv s21)))
  (define s23 (fire s22 'prompt/confirm '() (tv s22)))
  (check-false (directory-exists? sub))

  ;; ---------- 关闭文档：脏 → 问是否写入；不写入再问是否关闭 ----------
  (define s24 (set-tree! (session-set-focus s23 tid) tmp))
  (define s25 (fire s24 'tree/activate '() (tv s24)))
  (check-true (ws-open? (session-ws s25) tmp))
  (check-false (ws-dirty? (session-ws s25) (ed* s25) (editor-did* s25)))

  ;; 改一下 → 脏
  (define s25m (fire s25 'editor/insert (list "X") (evid s25)))
  (check-true (ws-dirty? (session-ws s25m) (ed* s25m) (editor-did* s25m)))

  ;; C-w → 「写入？(y/n)」；n → 「确认关闭？」；n → 不关、不写
  (define s25c (fire s25m 'file/close '() #f))
  (check-true (session-mode-active? s25c))
  (define s25n (fire s25c 'prompt/insert (list "n") (tv s25c)))
  (define s25c2 (fire s25n 'prompt/confirm '() (tv s25n)))
  (check-true (session-mode-active? s25c2))
  (define s25n2 (fire s25c2 'prompt/insert (list "n") (tv s25c2)))
  (define s25abort (fire s25n2 'prompt/confirm '() (tv s25n2)))
  (check-false (session-mode-active? s25abort))
  (check-true (ws-open? (session-ws s25abort) tmp))             ; 文档还在
  (check-true (ws-dirty? (session-ws s25abort) (ed* s25abort) (editor-did* s25abort)))

  ;; 再来：不写入（n）→ 确认关闭（y）→ 关闭，磁盘保持原样
  (define s25d (fire s25abort 'file/close '() #f))
  (define s25dn (fire s25d 'prompt/insert (list "n") (tv s25d)))
  (define s25d2 (fire s25dn 'prompt/confirm '() (tv s25dn)))
  (define s25dy (fire s25d2 'prompt/insert (list "y") (tv s25d2)))
  (define s25closed (fire s25dy 'prompt/confirm '() (tv s25dy)))
  (check-false (ws-open? (session-ws s25closed) tmp))
  (check-equal? (file->string tmp) "FILE\nsecond\n")            ; 未写入，磁盘原样
  (check-equal? (editor-view-string (ed* s25closed) (evid s25closed)) "")  ; scratch

  ;; 重开 → 改成 "SFILE\n..." → C-w → 写入 y → 关闭 + 磁盘更新
  (define s26 (set-tree! (session-set-focus s25closed tid) tmp))
  (define s27 (fire s26 'tree/activate '() (tv s26)))
  (check-true (ws-open? (session-ws s27) tmp))
  (define s28 (fire s27 'editor/insert (list "S") (evid s27)))
  (check-true (ws-dirty? (session-ws s28) (ed* s28) (editor-did* s28)))
  (define s28c (fire s28 'file/close '() #f))
  (define s28y (fire s28c 'prompt/insert (list "y") (tv s28c)))
  (define s29 (fire s28y 'prompt/confirm '() (tv s28y)))
  (check-false (ws-open? (session-ws s29) tmp))
  (check-equal? (file->string tmp) "SFILE\nsecond\n")

  (delete-directory/files dir)
  (displayln "lab/command.rkt: all tests passed"))

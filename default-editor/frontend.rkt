#lang racket

;;; default-editor/frontend.rkt —— 主编辑窗格：buffer（打开的文档）⊕ 自己的编辑策略
;;;
;;; 前端**只**管一件事：把 buffer 里当前文档的一个 view 编辑好、投影好。
;;; 它不知道文件树、状态栏、布局的存在 —— 那些通过 panel 协议 + 命令层接起来。
;;;
;;;   frontend = buffers（打开的文档注册表）⊕ provider（投影 face 的策略）
;;;
;;; 每个 buffer 有自己的 view（视口状态住在那），所以切换文档不丢光标 / 滚动。
;;; 「关窗口」与「关文档」在这里分得很清：本模块只做**关文档**（frontend-close）；
;;; 窗口显隐是 layout 的事，与本模块无关。

(require "../core/editor.rkt"
         "../core/api.rkt"
         "buffer.rkt"
         "layout.rkt"
         "panel.rkt"
         racket/file racket/path racket/list rackunit)

(provide
 frontend? frontend-buffers frontend-provider
 frontend-create frontend-add frontend-open-file
 frontend-close frontend-switch frontend-next frontend-prev
 frontend-focus frontend-resize frontend-project frontend-panel
 frontend-active-did frontend-active-vid frontend-active-entry
 frontend-path frontend-name frontend-dirty? frontend-string frontend-save
 frontend-text frontend-key frontend-undo frontend-redo
 frontend-toggle-line-numbers frontend-collapse
 default-provider)

;;; ---------- 值 ----------

(struct frontend (bs provider) #:transparent)
;; bs       : buffers   打开的文档注册表
;; provider : face-provider（前端投影策略；不存进文档）

(define (frontend-buffers fe) (frontend-bs fe))

;; 主文档默认 face：读 'face 属性键当 face；read-only 保留键映射成只读样式。
(define (default-provider ed did line)
  (define faces (editor-document-attrs-key-runs ed did line 'face))
  (define ros (editor-document-attrs-key-runs ed did line read-only-key))
  (append (for/list ([r (in-list faces)]) (list (car r) (cadr r) (caddr r)))
          (for/list ([r (in-list ros)]) (list (car r) (cadr r) (hash 'face 'read-only)))))

(define (frontend-active-did fe) (buffers-active (frontend-bs fe)))
(define (frontend-active-vid fe) (buffers-vid (frontend-bs fe) (frontend-active-did fe)))
(define (frontend-active-entry fe) (buffers-active-entry (frontend-bs fe)))
(define (frontend-path fe) (buffers-path (frontend-bs fe) (frontend-active-did fe)))
(define (frontend-name fe) (buffers-name (frontend-bs fe) (frontend-active-did fe)))
(define (frontend-dirty? ed fe) (buffers-dirty? ed (frontend-bs fe)))
(define (frontend-string ed fe) (editor-document->string ed (frontend-active-did fe)))

(define (frontend-focus ed fe)
  (define vid (frontend-active-vid fe))
  (if vid (editor-focus-view ed vid) ed))

;; 当前 view 的尺寸（新开文档默认沿用，之后 layout 会按矩形写回）。
(define (active-size ed fe)
  (define vid (frontend-active-vid fe))
  (if vid (values (editor-view-height ed vid) (editor-view-width ed vid))
      (values 24 80)))

(define (with-bs fe bs) (struct-copy frontend fe [bs bs]))

;;; ---------- 构造：首文档 / 追加文档 / 开文件 ----------

;; 建 editor + 第一个 buffer（主文档）。这是前端的唯一引导入口。
(define (frontend-create text height width
                         #:path [path #f]
                         #:name [name #f]
                         #:history? [history? #t]
                         #:line-numbers? [line-numbers? #f]
                         #:provider [provider default-provider])
  (define p (and path (path->complete-path path)))
  (define nm (or name (if p (path->string (file-name-from-path p)) "*scratch*")))
  (define ed (editor-open text (max 1 height) (max 1 width)
                          #:name nm #:history? history? #:line-numbers? line-numbers?))
  (define e (buffer-entry 0 0 p nm (editor-document-text-tick ed 0)))
  (values ed (frontend (buffers (list e) 0) provider)))

;; 追加一个文档并切过去（不关旧文档 —— 显式关闭见 frontend-close）。
(define (frontend-add ed fe text
                      #:path [path #f] #:name [name "*scratch*"]
                      #:history? [history? #t] #:line-numbers? [line-numbers? #f]
                      #:height [height #f] #:width [width #f])
  (define-values (h0 w0) (active-size ed fe))
  (define-values (ed1 bs1 did)
    (buffers-add ed (frontend-bs fe) text (or height h0) (or width w0)
                 #:path path #:name name #:history? history? #:line-numbers? line-numbers?))
  (define fe1 (with-bs fe bs1))
  (values (frontend-focus ed1 fe1) fe1))

;; 打开文件：已打开就切过去（不重复开），否则读盘新开。
(define (frontend-open-file ed fe path #:height [height #f] #:width [width #f])
  (define p (path->complete-path path))
  (cond
    [(not (file-exists? p)) (values ed fe #f (format "no such file: ~a" p))]
    [else
     (define existing (buffers-find-path (frontend-bs fe) p))
     (cond
       [existing
        (define fe1 (with-bs fe (buffers-activate (frontend-bs fe) existing)))
        (values (frontend-focus ed fe1) fe1 #f (format "switch to ~a" (file-name-from-path p)))]
       [else
        (define-values (ed1 fe1) (frontend-add ed fe (file->string p)
                                               #:path p
                                               #:name (path->string (file-name-from-path p))
                                               #:height height #:width width))
        (values ed1 fe1 #f (format "opened ~a" p))])]))

;;; ---------- 关闭 / 切换（文档生命周期，与窗口显隐无关） ----------

;; 关文档：从 buffer 摘掉 + 在 editor 里真正关掉（连带它的 view）。
;; 关的是当前文档就切到邻居；关掉最后一个则补一个 *scratch*（保证前端恒有文档可显示）。
(define (frontend-close ed fe [did (frontend-active-did fe)])
  (define e (buffers-entry (frontend-bs fe) did))
  (cond
    [(not e) (values ed fe)]
    [else
     (define h (editor-view-height ed (buffer-entry-vid e)))
     (define w (editor-view-width ed (buffer-entry-vid e)))
     (define bs1 (buffers-remove (frontend-bs fe) did))
     (define ed1 (editor-close-document ed did))
     (cond
       [(buffers-active bs1)
        (define fe1 (with-bs fe bs1))
        (values (frontend-focus ed1 fe1) fe1)]
       [else
        (define-values (ed2 bs2 _did) (buffers-add ed1 (buffers-empty) "" h w #:name "*scratch*"))
        (define fe2 (with-bs fe bs2))
        (values (frontend-focus ed2 fe2) fe2)])]))

(define (frontend-switch ed fe did)
  (define fe1 (with-bs fe (buffers-activate (frontend-bs fe) did)))
  (values (frontend-focus ed fe1) fe1))

(define (frontend-next ed fe) (frontend-switch ed fe (buffers-active (buffers-next (frontend-bs fe)))))
(define (frontend-prev ed fe) (frontend-switch ed fe (buffers-active (buffers-prev (frontend-bs fe)))))

;;; ---------- 磁盘 ----------

;; 保存当前文档（path 缺省 = buffer 的路径）。改路径 = 另存为。
(define (frontend-save ed fe [path #f])
  (define did (frontend-active-did fe))
  (define p (or path (buffers-path (frontend-bs fe) did)))
  (cond
    [(not p) (values ed fe #f "no file name")]
    [else
     (call-with-output-file p #:exists 'replace
       (lambda (o) (write-string (editor-document->string ed did) o)))
     (define bs1 (buffers-mark-saved ed (frontend-bs fe) did))
     (values ed (with-bs fe bs1) #t (format "saved ~a" p))]))

;;; ---------- 投影 / 尺寸 ----------

(define (frontend-project ed fe)
  (define vid (frontend-active-vid fe))
  (if vid (editor-view->screen ed vid (frontend-provider fe)) (screen-empty 1 1)))

(define (frontend-resize ed fe r)
  (define vid (frontend-active-vid fe))
  (if vid
      (editor-view-set-size ed vid (max 1 (rect-h r)) (max 1 (rect-w r)))
      ed))

(define (frontend-panel fe)
  (panel-open 'frontend fe
    #:project (lambda (ed st) (frontend-project ed st))
    #:resize (lambda (ed st r) (values (frontend-resize ed st r) st))
    #:refresh (lambda (ed st) (values ed st))
    #:sync (lambda (ed st) (values ed st))))

;;; ---------- 编辑命令 ----------

(define (frontend-text ed fe str)
  (editor-view-edit ed (frontend-active-vid fe) (edit-insert str)))

(define (frontend-undo ed fe) (editor-view-undo ed (frontend-active-vid fe)))
(define (frontend-redo ed fe) (editor-view-redo ed (frontend-active-vid fe)))

(define (frontend-toggle-line-numbers ed fe)
  (define vid (frontend-active-vid fe))
  (editor-view-set-line-numbers ed vid (not (editor-view-line-numbers? ed vid))))

(define (frontend-collapse ed fe)
  (editor-view-collapse-selections ed (frontend-active-vid fe)))

;; 键盘（仅文本区策略；Ctrl 组合与焦点切换由命令层决定）。
(define (frontend-key ed fe k alt? shift?)
  (define vid (frontend-active-vid fe))
  (cond
    [alt?
     (case k
       [(up) (values (editor-view-add-selection ed vid
                      (caret (editor-view-point-up ed vid (editor-view-point ed vid)))) #f)]
       [(down) (values (editor-view-add-selection ed vid
                        (caret (editor-view-point-down ed vid (editor-view-point ed vid)))) #f)]
       [else (values ed #f)])]
    [shift?
     (case k
       [(left right up down home end) (frontend-extend ed vid k)]
       [else (values ed #f)])]
    [else
     (case k
       [(left) (values (editor-view-left ed vid) #f)]
       [(right) (values (editor-view-right ed vid) #f)]
       [(up) (values (editor-view-up ed vid) #f)]
       [(down) (values (editor-view-down ed vid) #f)]
       [(home) (values (editor-view-home ed vid) #f)]
       [(end) (values (editor-view-end ed vid) #f)]
       [(pageup) (values (editor-view-scroll ed vid (- (editor-view-height ed vid))) #f)]
       [(pagedown) (values (editor-view-scroll ed vid (editor-view-height ed vid)) #f)]
       [(enter return newline) (editor-view-edit ed vid (edit-insert "\n"))]
       [(backspace) (editor-view-edit ed vid (edit-backspace))]
       [(delete) (editor-view-edit ed vid (edit-delete))]
       [(tab) (editor-view-edit ed vid (edit-insert "  "))]
       [else (values ed #f)])]))

(define (frontend-extend ed vid sym)
  (values (editor-view-map-primary ed vid
            (lambda (sel)
              (define h (selection-head sel))
              (define h* (case sym
                           [(left) (editor-view-point-left ed vid h)]
                           [(right) (editor-view-point-right ed vid h)]
                           [(up) (editor-view-point-up ed vid h)]
                           [(down) (editor-view-point-down ed vid h)]
                           [(home) (editor-view-point-home ed vid h)]
                           [(end) (editor-view-point-end ed vid h)]))
              (selection (selection-anchor sel) h*)))
          #f))

;;; ---------- 测试 ----------

(module+ test
  (define dir (make-temporary-file "edfe~a" 'directory))
  (define a (build-path dir "a.txt"))
  (call-with-output-file a #:exists 'replace (lambda (o) (display "abc" o)))

  ;; 构造 + 基本读口
  (define-values (ed0 fe0) (frontend-create "" 10 40))
  (check-true (frontend? fe0))
  (check-equal? (frontend-name fe0) "*scratch*")
  (check-equal? (frontend-active-did fe0) 0)
  (check-equal? (frontend-active-vid fe0) 0)
  (check-equal? (frontend-path fe0) #f)
  (check-false (frontend-dirty? ed0 fe0))
  (check-true (screen? (frontend-project ed0 fe0)))
  (check-equal? (screen-height (frontend-project ed0 fe0)) 10)

  ;; 编辑 → dirty
  (define-values (ed1 r1) (frontend-text ed0 fe0 "hi"))
  (check-equal? (frontend-string ed1 fe0) "hi")
  (check-true (frontend-dirty? ed1 fe0))
  (check-equal? (change-report-first-line r1) 0)

  ;; 打开文件：新开 buffer，旧文档保留
  (define-values (ed2 fe1 _q _m) (frontend-open-file ed1 fe0 a))
  (check-equal? (frontend-path fe1) (path->complete-path a))
  (check-equal? (frontend-string ed2 fe1) "abc")
  (check-equal? (frontend-name fe1) "a.txt")
  (check-false (frontend-dirty? ed2 fe1))
  (check-equal? (buffers-count (frontend-buffers fe1)) 2)
  (check-equal? (editor-document->string ed2 0) "hi")        ; scratch 还在

  ;; 已打开文件：切过去，不重复开
  (define-values (ed3 fe2 _q2 m2) (frontend-open-file ed2 fe1 a))
  (check-equal? (buffers-count (frontend-buffers fe2)) 2)
  (check-equal? (frontend-active-did fe2) (buffers-find-path (frontend-buffers fe2) a))

  ;; 切回 scratch / 轮换
  (define-values (_ed4 fe3) (frontend-switch ed3 fe2 0))
  (check-equal? (frontend-active-did fe3) 0)
  (define-values (_ed5 fe4) (frontend-next ed3 fe3))
  (check-equal? (frontend-active-did fe4) (buffers-find-path (frontend-buffers fe4) a))
  (define-values (_ed6 fe5) (frontend-prev ed3 fe4))
  (check-equal? (frontend-active-did fe5) 0)

  ;; 关文档：buffer 减少，view 一并关掉
  (define n-views-before (editor-view-count ed3))
  (define-values (ed7 fe6) (frontend-close ed3 fe3 0))
  (check-equal? (buffers-count (frontend-buffers fe6)) 1)
  (check-equal? (frontend-active-did fe6) (buffers-find-path (frontend-buffers fe6) a))
  (check-equal? (editor-view-count ed7) (sub1 n-views-before))

  ;; 关最后一个 → 补 scratch
  (define-values (ed8 fe7) (frontend-close ed7 fe6))
  (check-equal? (buffers-count (frontend-buffers fe7)) 1)
  (check-equal? (frontend-name fe7) "*scratch*")
  (check-equal? (frontend-string ed8 fe7) "")

  ;; 保存
  (define out (build-path dir "out.txt"))
  (define-values (ed9 fe8 _ok _msg) (frontend-save ed8 fe7 out))
  (check-equal? (file->string out) "")
  (define-values (edz fez) (frontend-add ed9 fe8 "Z" #:path out #:name "out.txt"))
  (define-values (ed10 fe9 ok10 msg10) (frontend-save edz fez))
  (check-true ok10)
  (check-equal? (file->string out) "Z")
  (check-true (string? msg10))
  (check-equal? ed10 edz)
  (check-equal? (buffers-path (frontend-buffers fe9) (frontend-active-did fe9)) (path->complete-path out))

  ;; 键盘：导航 + 插入
  (define-values (eda fea) (frontend-create "abc" 5 20))
  (define-values (edb _rb) (frontend-key eda fea 'right #f #f))
  (check-equal? (editor-view-point edb (frontend-active-vid fea)) (point 0 1))
  (define-values (edc _rc) (frontend-key edb fea 'enter #f #f))
  (check-equal? (frontend-string edc fea) "a\nbc")

  ;; shift 扩选
  (define-values (edd _rd) (frontend-key eda fea 'right #f #t))
  (check-true (not (caret? (editor-view-primary edd (frontend-active-vid fea)))))

  ;; 行号栏开关
  (check-false (editor-view-line-numbers? eda (frontend-active-vid fea)))
  (check-true (editor-view-line-numbers? (frontend-toggle-line-numbers eda fea) (frontend-active-vid fea)))

  ;; 面板：投影 / 尺寸 / 同步
  (define p (frontend-panel fea))
  (check-equal? (panel-id p) 'frontend)
  (check-equal? (screen-height (panel-project eda p)) 5)
  (define-values (edr pr) (panel-resize eda p (rect 3 4 8 12)))
  (check-equal? (editor-view-height edr (frontend-active-vid fea)) 12)
  (check-equal? (editor-view-width edr (frontend-active-vid fea)) 8)
  (define-values (eds _ps) (panel-sync edr pr))
  (check-equal? eds edr)

  (delete-directory/files dir)
  (displayln "frontend.rkt: all tests passed"))

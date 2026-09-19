#lang racket

;;; editor.rkt —— 最小无前端编辑器（只依赖 core/api.rkt + history.rkt）
;;;
;;; 没有终端、没有 io：把 core 的原子拼成一个能跑的无头编辑器，走完
;;; 「打开 → 编辑 → 导航 → 撤销/重做 → 高亮/只读 → 渲染成纯文本」的闭环，
;;; 并演示**局部更新**：每次操作返回「变更行区间」，只重标/重画改过的行。
;;;
;;; 本文件存在的全部意义：回答「一个编辑器到底依赖 core 的哪些名字」。
;;; 下方「依赖清单」里列出的，就是本文件用到的全部 core 名字；之外的名字它都用不到。

(require "core/api.rkt" "history.rkt" rackunit)

;; ── 依赖清单（core 侧，按用途）────────────────────────────
;;   文档   document-open  document-add-view  document-window  document->string
;;          document-line-count  document-line-ref
;;   编辑   document-edit  edit-char  edit-insert  edit-newline  edit-backspace
;;   导航   document-update-view  window-ensure-point
;;          window-goto  window-left  window-end  window-home
;;   撤销   document-apply-descs-trusted
;;   增量   edits-span  edit-change-desc  screen-diff-rows  screen-rows  screen-cols
;;   标注   document-put-properties-many  document-put-property  document-remove-property
;;          document-put-restrict  restrict  document-apply-patches  patch
;;   观察   window-point  point  document-get-property  document-read-only-at?
;;   渲染   window->screen  screen->text
;;   账本   history.rkt（消费层）：make-history  history-record
;;          history-pop-undo  history-pop-redo  step-undo-descs  step-replay-descs  step-point
;; ──────────────────────────────────────────────────────────

;;; ============ 状态 ============

(struct ed (doc active hist) #:transparent)   ; document + active 视图 + 撤销账本

(define (open-editor [text ""] [height 24] [width 80])
  (define-values (doc _) (document-add-view (document-open text) height width))
  (ed doc 0 (make-history)))

;;; ============ 编辑：唯一入口 document-edit，顺路记账 + 报变更行 ============
;;; 返回 (values 新状态 变更首行 变更末行)；没发生（no-op / 被拒）→ 变更行 #f #f。

(define (edit! a op)
  (define-values (doc* ch) (document-edit (ed-doc a) (ed-active a) op))
  (define-values (f l) (edits-span (if ch (list (edit-change-desc ch)) '())))
  (values (struct-copy ed a
            [doc doc*]
            [hist (if ch (history-record (ed-hist a) ch) (ed-hist a))])
          f l))

;;; ============ 导航：只动视图，无文本变更 ============

(define (nav! a win-fn)
  (struct-copy ed a
    [doc (document-update-view (ed-doc a) (ed-active a)
           (lambda (w) (window-ensure-point (win-fn w))))]))

;;; ============ 撤销 / 重做（同样报变更行）============

(define (undo! a)
  (define-values (st h*) (history-pop-undo (ed-hist a)))
  (cond
    [(not st) (values a #f #f)]
    [else
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (struct-copy ed a
               [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                                  (step-undo-descs st) (step-point st))]
               [hist h*])
             f l)]))

(define (redo! a)
  (define-values (st h*) (history-pop-redo (ed-hist a)))
  (cond
    [(not st) (values a #f #f)]
    [else
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (struct-copy ed a
               [doc (document-apply-descs-trusted (ed-doc a) (ed-active a)
                                                  (step-replay-descs st))]
               [hist h*])
             f l)]))

;;; ============ 语法高亮（全量 + 局部）============

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not|else)\\b")

;; [f,l] 行内的关键字 segs（patch 的 segs 是 (list line start end val)，key 在 patch 上）
(define (syntax-segs doc f l)
  (apply append
         (for/list ([line (in-range f (add1 l))])
           (define text (document-line-ref doc line))
           (for/list ([m (in-list (regexp-match-positions* keyword-rx text))])
             (list line (car m) (cdr m) 'keyword)))))

;; 只重标 [f,l]：patch 按 key「清旧写新」，不影响别的行、别的 key。
(define (re-highlight! a f l)
  (if f
      (struct-copy ed a
        [doc (document-apply-patches (ed-doc a)
                                     (list (patch 'face f l (syntax-segs (ed-doc a) f l))))])
      a))

;;; ============ 标注（单键写 / 清 / 只读）============

(define (set-face! a line start end val)
  (struct-copy ed a [doc (document-put-property (ed-doc a) line start end 'face val)]))
(define (clear-face! a line start end)
  (struct-copy ed a [doc (document-remove-property (ed-doc a) line start end 'face)]))
(define (read-only! a line start end)
  (struct-copy ed a [doc (document-put-restrict (ed-doc a) line start end (restrict #t))]))

;;; ============ 观察 ============

(define (text a) (document->string (ed-doc a)))
(define (cursor a) (window-point (document-window (ed-doc a) (ed-active a))))
(define (face a line col) (document-get-property (ed-doc a) line col 'face))
(define (read-only? a line col) (document-read-only-at? (ed-doc a) line col))

;;; ============ 渲染 ============

(define (render a)
  (screen->text (window->screen (document-window (ed-doc a) (ed-active a)))))

;; 两屏 diff 出变化行（局部重画依据；尺寸变了 → #f = 全量）
(define (changed-rows old new)
  (if (and (= (screen-rows old) (screen-rows new))
           (= (screen-cols old) (screen-cols new)))
      (screen-diff-rows old new)
      #f))

;;; ============ 走一遍 ============

(module+ main
  (define a0 (open-editor "abc" 1 40))
  (define a1 (re-highlight! a0 0 0))
  (printf "初始 (0,1) 面=~a\n" (face a1 0 1))
  (define-values (a2 f l) (edit! a1 (edit-insert "define ")))
  (printf "插入后文本=~s 改了第 ~a 行\n" (text a2) f)
  (define a3 (re-highlight! a2 f l))                    ; 只重标改过的行
  (printf "局部重标后 (0,1) 面=~a（define 被标上）\n" (face a3 0 1)))

;;; ============ 测试 ============

(module+ test
  (define a0 (open-editor ""))
  (check-equal? (text a0) "")
  (check-equal? (cursor a0) (point 0 0))

  ;; 编辑：连续单字符打字并成一步；粘贴（多字符）自成一步
  (define-values (a1 f1 l1) (edit! a0 (edit-char #\a)))
  (define-values (a2 _1 _2)  (edit! a1 (edit-char #\b)))
  (define-values (a3 _3 _4)  (edit! a2 (edit-char #\c)))
  (check-equal? (text a3) "abc")
  (check-equal? (list f1 l1) (list 0 0))                ; 单字符插入 → 变更 [0,0]
  (check-equal? (history-undo-depth (ed-hist a3)) 1)    ; 三个单字符并成一步
  (define-values (a4 f4 l4) (edit! a3 (edit-insert "de")))
  (check-equal? (text a4) "abcde")
  (check-equal? (list f4 l4) (list 0 0))
  (check-equal? (history-undo-depth (ed-hist a4)) 2)    ; 粘贴多字符 → 新的一步

  ;; 多行插入 → 变更行区间跨行
  (define-values (am fm lm) (edit! a0 (edit-insert "X\nY\n")))
  (check-equal? (text am) "X\nY\n")
  (check-equal? (list fm lm) (list 0 2))

  ;; 换行 / 退格（edit-* 家族其余成员）
  (define an0 (open-editor "abc"))
  (define-values (an1 _5 _6) (edit! (nav! an0 window-end) (edit-newline)))
  (check-equal? (text an1) "abc\n")
  (define-values (an2 _7 _8) (edit! an1 (edit-backspace)))
  (check-equal? (text an2) "abc")

  ;; 导航
  (define a5 (nav! a3 window-left))
  (check-equal? (cursor a5) (point 0 2))

  ;; 撤销 / 重做（也报变更行）
  (define-values (a6 uf ul) (undo! a3))
  (check-equal? (text a6) "")
  (check-equal? (cursor a6) (point 0 0))
  (check-equal? (list uf ul) (list 0 0))
  (define-values (a7 rf rl) (redo! a6))
  (check-equal? (text a7) "abc")
  (check-equal? (cursor a7) (point 0 3))
  (check-equal? (list rf rl) (list 0 0))

  ;; 全量高亮 + 单键写/清
  (define a8 (set-face! a7 0 0 2 'bold))
  (check-equal? (face a8 0 1) 'bold)
  (define a9 (clear-face! a8 0 0 2))
  (check-equal? (face a9 0 1) #f)

  ;; 增量重标：编辑造出一个关键字，只重标那一行就能看到
  (define h0 (open-editor "abc"))
  (define h1 (re-highlight! h0 0 0))
  (check-equal? (face h1 0 1) #f)                        ; 无关键字
  (define-values (h2 hf hl) (edit! h1 (edit-insert "define ")))
  (check-equal? (text h2) "define abc")
  (check-equal? (list hf hl) (list 0 0))
  (check-equal? (face h2 0 1) #f)                        ; 还没重标
  (define h3 (re-highlight! h2 hf hl))
  (check-equal? (face h3 0 1) 'keyword)                  ; define 被标上
  (check-equal? (face h3 0 8) #f)                        ; abc 部分没关键字
  (define-values (h4 _uf _ul) (undo! h3))
  (check-equal? (text h4) "abc")

  ;; 只读：区间内编辑被拒，不改文本、不入账、变更行 #f #f
  (define a10 (read-only! a9 0 0 2))
  (check-true (read-only? a10 0 1))
  (define a11 (nav! a10 (lambda (w) (window-goto w 0 1))))
  (define-values (a12 rf2 rl2) (edit! a11 (edit-char #\X)))
  (check-equal? (text a12) "abc")                        ; 没改
  (check-false rf2)
  (check-false rl2)

  ;; 渲染 + 局部重画（两屏 diff）
  (define ra (open-editor "abcd" 1 10))
  (check-equal? (render ra) "abcd")
  (define-values (rb _9 _10) (edit! ra (edit-char #\X)))
  (define old-screen (window->screen (document-window (ed-doc ra) 0)))
  (define new-screen (window->screen (document-window (ed-doc rb) 0)))
  (check-equal? (changed-rows old-screen new-screen) (list 0))  ; 只有第 0 行变了

  (displayln "editor.rkt: all tests passed"))

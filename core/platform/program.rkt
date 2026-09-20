#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt"
         "../doc/buffer.rkt" "../doc/batch.rkt" "../doc/patch.rkt"
         "../viewport/window.rkt" "../atom/restrict.rkt"
         "state.rkt" "write.rkt" "neutral.rkt" "reaction.rkt" rackunit)

;;; platform/program.rkt —— 程序面：内容变更 + 显式视图命令
;;;
;;; 程序操作的语义：
;;;   · 内容变更默认 **none**：只换 buffer 值，光标/视口字面不动（只夹紧合法性）。
;;;     需要光标跟随文本时显式给 #:reaction 'map。可在编辑点留下可撤销的一步。
;;;   · 视图命令都是「只动指定的那个 view」，绝不镜像、不抢焦点、不 ensure。
;;;
;;; 用户面（焦点/leader/ensure/账本）在 command.rkt。

(provide
 editor-edit-at
 editor-edit-at-batch
 ;; 显式 view 命令（程序面：按 vid 定位，只动指定 view，不经过焦点）
 editor-view-set-point
 editor-view-set-selections
 editor-view-set-size
 editor-view-set-mode
 editor-view-set-top-line
 editor-view-set-top-seg
 editor-view-set-left-col
 editor-view-set-sync
 editor-view-set-buffer
 ;; focus 糖（用户面便捷；程序面请用上面的 editor-view-*）
 editor-set-point
 editor-set-selections
 editor-set-mode
 editor-set-size
 editor-set-top-line
 editor-set-top-seg
 editor-set-left-col
 ;; 标注写（程序面：改 buffer 的标注，不碰文本/光标）
 editor-put-property
 editor-remove-property
 editor-put-properties-many
 editor-put-restrict
 editor-remove-restrict
 editor-apply-patches)

;; 在 bid 的显式位置 p 编辑。op : buffer point → (or/c #f edit-desc)。
;; 返回 (values editor (or/c #f change-report))。
;; #:reaction  'none（默认）| 'map   内容变更后视图怎么反应
;; #:trusted?  #t 跳过 read-only 守卫（格式化器）
;; #:record?   #t 记一步账本（pre-point = 夹紧后的编辑点）
(define (editor-edit-at ed bid p op
                        #:reaction [reaction 'none]
                        #:trusted? [trusted? #f]
                        #:record? [record? #f])
  (define b0 (editor-buffer ed bid))
  (define d (op b0 (selection p p)))
  (cond
    [(not d) (values ed #f)]
    [else
     (define-values (ed* d*) (editor-apply-edit ed bid d (not trusted?)))
     (cond
       [(not d*) (values ed #f)]
       [else
        (define b* (editor-buffer ed* bid))
        (define ed** (case reaction
                       [(none) (editor-clamp-views ed* bid)]
                       [(map)  (editor-map-views ed* bid b* (list d*))]
                       [else (error 'editor-edit-at "reaction 必须是 'none 或 'map，得到 ~a" reaction)]))
        (define ed*** (if record?
                          (editor-record-history
                           ed** bid
                           (edit-change d* (buffer-edit-desc-inverse b0 d*) (edit-desc-start d*)))
                          ed**))
        (define-values (f l) (edits-span (list d*)))
        (values ed*** (change-report f l (list d*)))])]))

;; 批量：descs 同坐标系、互不重叠（= LSP TextEdit[]）。被守卫拒的静默丢弃
;; （要强制用 #:trusted? #t）。#:reaction 'none（默认）| 'map。#:record? #t → 整批记**一步**。
;; 返回 (values editor (or/c #f change-report))；report 的 edits = 实际施加的 descs（施加顺序）。
(define (editor-edit-at-batch ed bid descs
                              #:reaction [reaction 'none]
                              #:trusted? [trusted? #f]
                              #:record? [record? #f])
  (define-values (ed* ds ivs) (editor-apply-edit-batch ed bid descs (not trusted?)))
  (cond
    [(null? ds) (values ed #f)]
    [else
     (define b* (editor-buffer ed* bid))
     (define ed** (case reaction
                    [(none) (editor-clamp-views ed* bid)]
                    [(map)  (editor-map-views ed* bid b* ds)]
                    [else (error 'editor-edit-at-batch "reaction 必须是 'none 或 'map，得到 ~a" reaction)]))
     (define ed*** (if record?
                       (editor-record-batch ed** bid ds (reverse ivs) (edits-min-start ds))
                       ed**))
     (define-values (f l) (edits-span ds))
     (values ed*** (change-report f l ds))]))

;; 批量没有唯一编辑点；pre-point 取最左（文档序）施加点，撤销后光标落到最靠前的改动处。
(define (edits-min-start ds)
  (for/fold ([p #f]) ([d (in-list ds)])
    (define s (edit-desc-start d))
    (if (or (not p) (point<? s p)) s p)))

;;; ---------- 显式视图命令（程序面：只动一个 view，不镜像、不抢焦点） ----------
;; 全部按 vid 定位，绝不读也不改 focus；同 buffer 其它 view 一律不动。

(define (view-window-of ed vid) (view-window (editor-view-ref ed vid)))

(define (editor-view-set-point ed vid p)
  (editor-put-view ed vid (window-set-point (view-window-of ed vid) p)))

(define (editor-view-set-selections ed vid sels)
  (editor-put-view ed vid (window-set-selections (view-window-of ed vid) sels)))

(define (editor-view-set-size ed vid height width)
  (editor-put-view ed vid (window-set-size (view-window-of ed vid) height width)))

(define (editor-view-set-mode ed vid mode)
  (editor-put-view ed vid (window-set-mode (view-window-of ed vid) mode)))

(define (editor-view-set-top-line ed vid n)
  (editor-put-view ed vid (window-set-top-line (view-window-of ed vid) n)))

(define (editor-view-set-top-seg ed vid n)
  (editor-put-view ed vid (window-set-top-seg (view-window-of ed vid) n)))

(define (editor-view-set-left-col ed vid n)
  (editor-put-view ed vid (window-set-left-col (view-window-of ed vid) n)))

;; 结构变换：换指定 view 的同步策略 / 属主；不触发同步。
(define (editor-view-set-sync ed vid sync)
  (editor-set-view-sync ed vid sync))
(define (editor-view-set-buffer ed vid bid)
  (editor-set-view-buffer ed vid bid))

;;; ---------- focus 糖（用户面便捷） ----------

(define (editor-set-point ed p)
  (editor-view-set-point ed (view-id (editor-focused-view ed)) p))

(define (editor-set-selections ed sels)
  (editor-view-set-selections ed (view-id (editor-focused-view ed)) sels))

(define (editor-set-mode ed mode)
  (editor-view-set-mode ed (view-id (editor-focused-view ed)) mode))

(define (editor-set-size ed height width)
  (editor-view-set-size ed (view-id (editor-focused-view ed)) height width))

(define (editor-set-top-line ed n)
  (editor-view-set-top-line ed (view-id (editor-focused-view ed)) n))

(define (editor-set-top-seg ed n)
  (editor-view-set-top-seg ed (view-id (editor-focused-view ed)) n))

(define (editor-set-left-col ed n)
  (editor-view-set-left-col ed (view-id (editor-focused-view ed)) n))

;;; ---------- 标注写（改 buffer 的标注；不碰文本，光标自然不动） ----------

(define (editor-put-property ed bid start end key val)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-property b start end key val))))
(define (editor-remove-property ed bid start end key)
  (editor-update-buffer ed bid (lambda (b) (buffer-remove-property b start end key))))
(define (editor-put-properties-many ed bid segs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-properties-many b segs))))
(define (editor-put-restrict ed bid start end rs)
  (editor-update-buffer ed bid (lambda (b) (buffer-put-restrict b start end rs))))
(define (editor-remove-restrict ed bid start end)
  (editor-update-buffer ed bid (lambda (b) (buffer-remove-restrict b start end))))
(define (editor-apply-patches ed bid patches)
  (editor-update-buffer ed bid (lambda (b) (buffer-apply-patches b patches))))

;;; ---------- 测试 ----------

(module+ test
  ;; 默认 none：内容变了，光标字面不动
  (define e0 (editor-open "hello"))
  (define-values (e1 r1) (editor-edit-at e0 0 (point 0 0) (edit-splice (point 0 0) (point 0 0) "XY")))
  (check-equal? (editor-buffer->string e1 0) "XYhello")
  (check-equal? (editor-point e1) (point 0 0))          ; none
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (change-report-edits r1)
                (list (edit-desc (point 0 0) (point 0 0) "XY")))   ; 施加顺序的生效 desc
  (check-false (editor-can-undo? e1 0))                 ; 默认不记账本

  ;; 'map：光标跟随文本（光标在编辑点之后才会右移）
  (define e0s (editor-set-point e0 (point 0 3)))
  (define-values (e2 _r2) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY") #:reaction 'map))
  (check-equal? (editor-buffer->string e2 0) "hXYello")
  (check-equal? (editor-point e2) (point 0 5))          ; (0,3) 映射到 (0,5)
  ;; 同一场景改成 none：光标字面不动
  (define-values (e2n _r2n) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY")))
  (check-equal? (editor-point e2n) (point 0 3))

  ;; #:record? #t：记一步，pre-point = 编辑点
  (define-values (e3 _r3) (editor-edit-at e0 0 (point 0 2) (edit-insert "Z") #:record? #t))
  (check-true (editor-can-undo? e3 0))

  ;; #:trusted? #t 跳过 read-only 守卫
  (define tr (editor-put-restrict (editor-open "abc") 0 (point 0 0) (point 0 3) (restrict #t)))
  (define-values (tr1 rtr1) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X)))
  (check-false rtr1)                                    ; 守卫版被拒
  (check-equal? (editor-buffer->string tr1 0) "abc")
  (define-values (tr2 _rtr2) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X) #:trusted? #t))
  (check-equal? (editor-buffer->string tr2 0) "aXbc")

  ;; 标注写：只改标注、不碰文本/光标
  (define an (editor-put-property (editor-open "hello") 0 (point 0 0) (point 0 5) 'face 'bold))
  (check-equal? (editor-get-property an 0 (point 0 2) 'face) 'bold)

  ;; 显式视图命令：按 vid 定位，只动目标 view，不动焦点
  (define v0 (editor-open "l0\nl1\nl2\nl3\nl4" 2 10))
  (define-values (v1 vv) (editor-add-view v0 0 2 10 #:focus? #f))
  (define v2 (editor-view-set-top-line v1 vv 2))
  (check-equal? (editor-view-top-line v2 vv) 2)          ; 目标 view 动了
  (check-equal? (editor-view-top-line v2 0) 0)           ; 另一个 view 不动
  (define v3 (editor-view-set-left-col v2 vv 3))
  (check-equal? (editor-view-left-col v3 vv) 3)
  (define v4 (editor-view-set-mode v3 vv 'wrap))
  (check-equal? (editor-view-mode v4 vv) 'wrap)
  (check-equal? (editor-view-mode v4 0) 'clip)
  (define v5 (editor-view-set-sync v4 vv 'follow))
  (check-equal? (editor-view-sync v5 vv) 'follow)

  ;; wrap 下的折行段：top-seg 可写且被夹紧到合法域
  (define ts0 (editor-open "abcdefghij" 2 3))
  (define ts1 (editor-view-set-mode ts0 0 'wrap))
  (define ts2 (editor-view-set-top-seg ts1 0 1))
  (check-equal? (editor-view-top-seg ts2 0) 1)
  (define-values (v5b other) (editor-open-buffer v5 "other" "OTHER" 2 10 #:focus? #f))
  (define v6 (editor-view-set-buffer v5b vv other))
  (check-equal? (editor-view-buffer-id v6 vv) other)
  (check-equal? (editor-focused-buffer-id v6) 0)         ; 焦点不动

  ;; focus 糖仍作用于焦点 view
  (define v7 (editor-view-set-point v6 0 (point 1 0)))
  (check-equal? (editor-view-point v7 0) (point 1 0))
  ;; 焦点 view 写糖（与 editor-view-set-* 镜像）
  (define v8 (editor-set-top-line (editor-set-left-col (editor-set-mode v7 'wrap) 2) 1))
  (check-equal? (editor-top-line v8) 1)
  (check-equal? (editor-left-col v8) 2)
  (check-equal? (editor-mode v8) 'wrap)

  ;; 批量：一次施多条，记一步，report.edits 为施加顺序（起点倒序）
  (define b0 (editor-open "abcd\nefgh"))
  (define-values (b1 rb)
    (editor-edit-at-batch b0 0 (list (edit-desc (point 0 1) (point 0 1) "X")
                                     (edit-desc (point 1 2) (point 1 2) "Y"))
                          #:record? #t))
  (check-equal? (editor-buffer->string b1 0) "aXbcd\nefYgh")
  (check-equal? (change-report-edits rb)
                (list (edit-desc (point 1 2) (point 1 2) "Y")
                      (edit-desc (point 0 1) (point 0 1) "X")))
  (check-equal? (editor-undo-depth b1 0) 1)                    ; 整批一步
  (check-equal? (editor-point b1) (point 0 0))                 ; 默认 none：光标不动

  ;; 批量被守卫拒 → 整体没发生；#:trusted? #t 强施
  (define bt (editor-put-restrict (editor-open "abc") 0 (point 0 0) (point 0 3) (restrict #t)))
  (define-values (bt1 rbt1) (editor-edit-at-batch bt 0 (list (edit-desc (point 0 1) (point 0 1) "X"))))
  (check-false rbt1)
  (check-equal? (editor-buffer->string bt1 0) "abc")
  (define-values (bt2 _rbt2) (editor-edit-at-batch bt 0 (list (edit-desc (point 0 1) (point 0 1) "X")) #:trusted? #t))
  (check-equal? (editor-buffer->string bt2 0) "aXbc")

  (displayln "program.rkt: all tests passed"))

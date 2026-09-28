#lang racket

(require "base/track.rkt" "base/line.rkt" "base/edit.rkt"
         "base/point.rkt" "base/range.rkt" "base/change.rkt")

;;; document.rkt —— 文档 = 文本 + 属性
;;;
;;; 属性只有**两种**：
;;;     高亮 highlight   每字符一个 face（语法高亮；#f = 无）
;;;     只读 readonly    每字符一个布尔（#t = 不可写）
;;;
;;;     document = 文本轨  ⊕  高亮轨  ⊕  只读轨
;;;
;;; 三条轨共享同一套行划分（行数一致、每行文本字符数 == 属性格数），document-aligned? 校验。
;;; 文本轨行 = string，属性轨行 = vector。
;;;
;;; **属性轨惰性**：highlight / readonly 可为 #f = “整轨全默认”。空文档就是两条 #f，
;;; 不分配任何属性格。文本编辑对“全默认”封闭（插/删的都是默认格，结果仍全默认），
;;; 所以文本编辑遇到 #f 直接保持 #f；只有**属性编辑**才 materialize 出真轨（一次 O(文档)）。
;;;
;;; 编辑入口：
;;;     document-edit-tracks       文本编辑：三条轨一起施（自动扇出，保持对齐）
;;;     document-edit-highlight  只改高亮
;;;     document-edit-readonly   只改只读
;;;
;;; 持久化：与 track 一致，旧 document 值天然保留（undo = 换旧值）。

(provide
 ;; ---------- 类型 ----------
 (struct-out document)
 (struct-out clipboard)

 ;; ---------- 构造 ----------
 document-open
 clipboard-of-text

 ;; ---------- 读 / 校验 ----------
 document->string document-range-text document-change-text
 document-highlight-at document-readonly-at?
 document-highlight-row document-readonly-row
 document-highlight-range? document-readonly-range? document-editable?
 document-aligned?

 ;; ---------- 写：文本轨（守只读 / -ignore-readonly） ----------
 document-edit-tracks
 document-insert document-insert-ignore-readonly
 document-delete document-delete-ignore-readonly
 document-replace document-replace-ignore-readonly

 ;; ---------- 写：属性轨 ----------
 document-edit-highlight document-edit-readonly
 document-highlight-fill document-readonly-fill

 ;; ---------- 剪贴板 ----------
 document-copy document-copy-text
 document-paste document-paste-ignore-readonly)

;;; ---------- 数据 ----------

(struct document (text highlight readonly) #:transparent)
;; text      : track（行 = string）
;; highlight : (or/c #f track)   #f = 整轨全默认；否则行 = vector（格值 = face / #f）
;; readonly  : (or/c #f track)   #f = 整轨全默认；否则行 = vector（格值 = #t / #f）

;;; ---------- 构造 ----------

;; 与文本同形、值全为 default 的属性轨。
(define (attr-track-for text default)
  (track-of-list (for/list ([l (in-list (track->list text))])
                   (make-vector (string-length l) default))
                 (track-max text)))

(define (document-open s [chunk-lines default-chunk-lines])
  (document (track-of-list (string->lines s) chunk-lines) #f #f))

(define (document->string bd) (lines->string (track->list (document-text bd))))

;;; ---------- 编辑 ----------

;; 文本编辑：三条轨一起施同一个编辑（ed 必须是行 payload 自适应的）。
;; 属性轨为 #f（全默认）时保持 #f —— 插/删的都是默认格，封闭。
(define (edit-attr a ed) (and a (ed a)))
(define (document-edit-tracks bd ed)
  (document (ed (document-text bd))
            (edit-attr (document-highlight bd) ed)
            (edit-attr (document-readonly bd) ed)))

;; 只改高亮 / 只改只读；首次编辑时按当前文本行长 materialize 出真轨。
(define (document-edit-highlight bd ed)
  (document (document-text bd)
            (ed (or (document-highlight bd) (attr-track-for (document-text bd) #f)))
            (document-readonly bd)))
(define (document-edit-readonly bd ed)
  (document (document-text bd)
            (document-highlight bd)
            (ed (or (document-readonly bd) (attr-track-for (document-text bd) #f)))))

;; 赋值糖：把 [l0,c0)..(l1,c1) 的高亮设为 face / 只读设为 flag。
(define (document-highlight-fill bd l0 c0 l1 c1 face)
  (document-edit-highlight bd (edit-fill l0 c0 l1 c1 face)))
(define (document-readonly-fill bd l0 c0 l1 c1 flag)
  (document-edit-readonly bd (edit-fill l0 c0 l1 c1 flag)))

;;; ---------- 属性查询（高亮 / 只读成对） ----------

;; 高亮格：face / #f。整轨 #f（全默认）→ #f。
(define (document-highlight-at bd line col)
  (define a (document-highlight bd))
  (and a (let ([l (track-ref a line)]) (and (< col (line-length l)) (line-ref l col)))))

;; 只读格：#t / #f。整轨 #f（全默认）→ #f。
(define (document-readonly-at? bd line col)
  (define a (document-readonly bd))
  (and a (let ([l (track-ref a line)]) (and (< col (line-length l)) (line-ref l col)))))

;; 整行属性格（向量视图）：真轨取行；整轨 #f → 按文本行长造全默认向量。
;; 纯读、不改惰性；让“读整行”的调用方不必知道 #f。
(define (document-attr-row a text-line line)
  (if a (track-ref a line) (make-vector (string-length text-line) #f)))

(define (document-highlight-row bd line)
  (document-attr-row (document-highlight bd) (track-ref (document-text bd) line) line))
(define (document-readonly-row bd line)
  (document-attr-row (document-readonly bd) (track-ref (document-text bd) line) line))

;; 区间 [l0,c0)..(l1,c1) 内是否有非默认的属性格。整轨 #f → 无。
(define (document-attr-range? t l0 c0 l1 c1)
  (and t
       (for/or ([i (in-range l0 (add1 l1))])
         (define l (track-ref t i))
         (define a (if (= i l0) c0 0))
         (define b (if (= i l1) c1 (line-length l)))
         (for/or ([j (in-range a b)]) (and (line-ref l j) #t)))))

(define (document-highlight-range? bd l0 c0 l1 c1)
  (document-attr-range? (document-highlight bd) l0 c0 l1 c1))

(define (document-readonly-range? bd l0 c0 l1 c1)
  (document-attr-range? (document-readonly bd) l0 c0 l1 c1))

;;; ---------- 用户编辑 / 程序编辑：成对（守 vs -ignore-readonly） ----------
;;; 约定：**基础名 = 用户编辑（守只读）**；**-ignore-readonly = 程序编辑（不守）**。
;;; 两者签名与返回一致，切换只改后缀：
;;;     (document-insert bd line col text …)                  ; 用户：命中只读则拒
;;;     (document-insert-ignore-readonly bd line col text …)   ; 程序：直接改
;;; 都返回 (values document change ok?)：
;;;     change = 本次变更描述（span->change）；**无实际变更时 change = #f**；
;;;     ok? = #f 表示被只读挡住（仅守版会），此时 change 也是 #f；
;;;     change = #f 且 ok? = #t = 空编辑（如 insert ""）：通过但什么都没改。
;;; 底层闭包 edit-* 是更原始的一层（无 document、无守卫）。

;; 零宽插入看插入点的格（行尾除外）；非空区间看区间内是否有只读格。
(define (document-readonly-block? bd l0 c0 l1 c1)
  (if (and (= l0 l1) (= c0 c1))
      (let ([len (line-length (track-ref (document-text bd) l0))])
        (and (< c0 len) (document-readonly-at? bd l0 c0)))
      (document-readonly-range? bd l0 c0 l1 c1)))

(define (document-editable? bd l0 c0 l1 c1)
  (not (document-readonly-block? bd l0 c0 l1 c1)))

(define (document-replace* bd l0 c0 l1 c1 text sticky default guard?)
  (cond
    [(and guard? (document-readonly-block? bd l0 c0 l1 c1)) (values bd #f #f)]
    [(and (= l0 l1) (= c0 c1) (string=? text "")) (values bd #f #t)]   ; 空编辑 = 无变更
    [else
     (define sp (span (point l0 c0) (point l1 c1) text))
     (values (document-edit-tracks bd (span->edit sp sticky default))
             (span->change sp)
             #t)]))

(define (document-replace bd l0 c0 l1 c1 text [sticky 'none] [default #f])
  (document-replace* bd l0 c0 l1 c1 text sticky default #t))
(define (document-replace-ignore-readonly bd l0 c0 l1 c1 text [sticky 'none] [default #f])
  (document-replace* bd l0 c0 l1 c1 text sticky default #f))

(define (document-insert bd line col text [sticky 'none] [default #f])
  (document-replace bd line col line col text sticky default))
(define (document-insert-ignore-readonly bd line col text [sticky 'none] [default #f])
  (document-replace-ignore-readonly bd line col line col text sticky default))

(define (document-delete bd l0 c0 l1 c1)
  (document-replace bd l0 c0 l1 c1 ""))
(define (document-delete-ignore-readonly bd l0 c0 l1 c1)
  (document-replace-ignore-readonly bd l0 c0 l1 c1 ""))

;;; ---------- 取文本（按区间） ----------

;; 取区间 [start,end) 的文本。range 是纯位置，故从文本轨切。
(define (document-range-text bd r)
  (define r* (range-normalize r))
  (lines->string (range-lines (document-text bd)
                              (point-line (range-start r*)) (point-col (range-start r*))
                              (point-line (range-end r*)) (point-col (range-end r*)))))

;; 取一次变更插入的文本 = 新文档在 change.after 区间上的切片。
;; change 不存文本，要内容时用这个现取。
(define (document-change-text bd ch)
  (document-range-text bd (change-after ch)))

;;; ---------- 复制 / 粘贴（剪贴板） ----------
;;; 剪贴板 clipboard 携带**与文本行对齐**的三样：文本行、高亮行、只读行（富粘贴）。
;;; 只要文本时用 clipboard-of-text（属性全 default）或直接用 document-insert。

;; 从一个文档区间 [l0,c0)..(l1,c1) 抽出某条轨的行片段。
(define (range-lines t l0 c0 l1 c1)
  (define (row i) (track-ref t i))
  (cond
    [(= l0 l1) (list (line-slice (row l0) c0 c1))]
    [else (append (list (line-slice (row l0) c0 (line-length (row l0))))
                  (for/list ([i (in-range (add1 l0) l1)]) (row i))
                  (list (line-slice (row l1) 0 c1)))]))

(struct clipboard (text highlight readonly) #:transparent)
;; text / highlight / readonly : (listof 行片段)，三者同行划分

(define (document-copy bd l0 c0 l1 c1)
  (define text-lines (range-lines (document-text bd) l0 c0 l1 c1))
  (clipboard text-lines
             (attr-lines (document-highlight bd) text-lines l0 c0 l1 c1)
             (attr-lines (document-readonly bd) text-lines l0 c0 l1 c1)))

;; 属性行片段：真轨直接抽；整轨 #f → 按文本片段长度造全默认格。
(define (attr-lines a text-lines l0 c0 l1 c1)
  (if a
      (range-lines a l0 c0 l1 c1)
      (for/list ([tl (in-list text-lines)]) (make-vector (string-length tl) #f))))

;; 只要文本的剪贴板（外部粘贴：高亮/只读全 default）。
(define (document-copy-text bd l0 c0 l1 c1)
  (clipboard-of-text (lines->string (range-lines (document-text bd) l0 c0 l1 c1))))

(define (clipboard-of-text text [hl-default #f] [ro-default #f])
  (define lines (string->lines text))
  (clipboard lines
             (for/list ([l lines]) (make-vector (string-length l) hl-default))
             (for/list ([l lines]) (make-vector (string-length l) ro-default))))

;; 把 clipboard 各轨的行片段拼到目标位置的某条轨上（按 payload 类型自动分派）。
(define (splice-clipboard-lines t line col pieces)
  (define l0 (track-ref t line))
  (define head (line-slice l0 0 col))
  (define tail (line-slice l0 col (line-length l0)))
  (define k (length pieces))
  (define new-lines
    (cond
      [(= k 1) (list (line-append (line-append head (car pieces)) tail))]
      [else (append (list (line-append head (car pieces)))
                    (take (drop pieces 1) (- k 2))
                    (list (line-append (last pieces) tail)))]))
  (track-splice t line (add1 line) new-lines))

(define (document-paste* bd line col cp guard?)
  (define text (lines->string (clipboard-text cp)))
  (cond
    [(and guard? (document-readonly-block? bd line col line col)) (values bd #f #f)]
    [(string=? text "") (values bd #f #t)]                            ; 空剪贴板 = 无变更
    [else
     (values (document (splice-clipboard-lines (document-text bd) line col (clipboard-text cp))
                       (paste-attr (document-highlight bd) (document-text bd) line col (clipboard-highlight cp))
                       (paste-attr (document-readonly bd) (document-text bd) line col (clipboard-readonly cp)))
             ;; 粘贴 = 在 (line,col) 零宽插入一段文本。
             (span->change (span (point line col) (point line col) text))
             #t)]))

;; 目标属性轨为 #f：剪贴板片段也全默认 → 保持 #f；否则 materialize 再拼。
(define (pieces-default? pieces)
  (for/and ([p (in-list pieces)])
    (for/and ([v (in-vector p)]) (not v))))

(define (paste-attr a text line col pieces)
  (cond
    [a (splice-clipboard-lines a line col pieces)]
    [(pieces-default? pieces) #f]
    [else (splice-clipboard-lines (attr-track-for text #f) line col pieces)]))

(define (document-paste bd line col cp)
  (document-paste* bd line col cp #t))
(define (document-paste-ignore-readonly bd line col cp)
  (document-paste* bd line col cp #f))

;;; ---------- 校验 ----------

(define (document-aligned? bd)
  (define rows (track->list (document-text bd)))
  (define (ok? t)
    (or (not t)
        (let ([arows (track->list t)])
          (and (= (length rows) (length arows))
               (for/and ([l rows] [a arows]) (= (string-length l) (line-length a)))))))
  (and (ok? (document-highlight bd)) (ok? (document-readonly bd))))

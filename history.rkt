#lang racket

(require racket/list
         "core/api.rkt"
         rackunit)

;;; history.rkt —— 撤销/重放账本（**消费层**，不是 core，见 ARCHITECTURE §8.5）
;;;
;;; 归属（§8.5）：文本变更走 document（撤销/重放都是 `document-apply-descs-trusted`，
;;; 只有它能 rebase 所有视图）；本模块只管账本——记不记、和谁并、几步。所以它是纯数据：
;;; 不碰 window、不 require document 的实现，只认识 edit-change / edit-desc 和 point。
;;;
;;; 一步必须**自含正反两向**（§8.5）——撤销不许留快照（快照式每步 8MB×3）：
;;;   replay-descs 重放用（desc 自带 new-text，不需旧文本）
;;;   undo-descs   撤销用（逆只能由「编辑前的 buffer」导出，故在编辑时捕获）
;;; 两者合起来才闭合：撤销到底再重放能精确回到原状态。
;;;
;;; ⚠ 记一步时，逆必须从**编辑前**的 buffer 导出（`buffer-edit-desc-inverse` 的 b）。
;;; 用编辑后的 buffer 会**静默写坏历史**：desc 不含旧文本，逆里的文本是从 b 的 [s..e)
;;; 读出来的，编辑后那里已是新内容。实测：删 "abcdef" 的 'b'，用后态求逆得到「插回 'c'」
;;; → 撤销出 "accdef"，不报任何错；而**纯插入时两态恰好相同**，所以打字路径看不出错，
;;; 只在删除路径爆（探针见 §8.5）。
;;;
;;; 本模块不替调用方「应用」——`main.rkt` 拿到 step 后用 `document-apply-descs-trusted`
;;; 一次落回整组 desc（§8.5）。

(provide
 (struct-out step)
 (struct-out history)
 make-history
 history-record
 history-pop-undo
 history-pop-redo
 history-can-undo?
 history-can-redo?
 history-undo-depth
 history-redo-depth)

;; 字段名自带方向与次序：两个列表存的是**相反次序**，而单元素 step（绝大多数）看不出
;; 差别 —— 所以不许用中性名字（原名 `descs`/`invs`，见 ARCHITECTURE §8.5）。
(struct step (replay-descs undo-descs pre-point) #:transparent)
;; replay-descs : (listof edit-desc)  重放：正序依次 apply（desc 自带 new-text，不需旧文本）
;; undo-descs   : (listof edit-desc)  撤销：正序依次 apply（与 replay-descs 相反次序）
;; pre-point    : point               该步开始前 active 视图的光标（撤销后回到这里）

(struct history (undo redo) #:transparent)
;; undo / redo : (listof step)  栈顶在前

(define (make-history) (history '() '()))

(define (history-can-undo? h) (pair? (history-undo h)))
(define (history-can-redo? h) (pair? (history-redo h)))
(define (history-undo-depth h) (length (history-undo h)))
(define (history-redo-depth h) (length (history-redo h)))

;;; ---------- 合并规则：结构判定（无时钟、无状态，§8.5）----------

;; 单字符、非换行的纯插入
(define (char-insert? d)
  (define t (edit-desc-new-text d))
  (and (= (edit-desc-s-line d) (edit-desc-e-line d))
       (= (edit-desc-s-col d) (edit-desc-e-col d))
       (= 1 (string-length t))
       (not (memv (string-ref t 0) '(#\newline #\return)))))

;; 单字符、非换行的纯删除（跨行删除 = 行合并，不算连续段）
(define (char-delete? d)
  (and (= (edit-desc-s-line d) (edit-desc-e-line d))
       (= (edit-desc-e-col d) (add1 (edit-desc-s-col d)))
       (string=? (edit-desc-new-text d) "")))

;; 新 desc 能否并进栈顶那一步：打字连续段 / 删除连续段（退格向左、前向删除同点）。
;; 坐标可比性：d 在新坐标系、pl 在旧坐标系，但删除只移动**起点左侧**的坐标，
;; 而下面的比较全发生在 pl 起点及其左侧 —— 数字可直接比。
;; （取 last 是 O(段长)/次按键；段长由人手打字决定，可忽略。）
(define (step-merge? prev d)
  (define pl (last (step-replay-descs prev)))
  (cond
    [(and (char-insert? pl) (char-insert? d))
     (define ap (edit-desc-after-position pl))
     (and (= (edit-desc-s-line d) (point-line ap))
          (= (edit-desc-s-col d) (point-col ap)))]
    [(and (char-delete? pl) (char-delete? d))
     (or (and (= (edit-desc-e-line d) (edit-desc-s-line pl))     ; 退格：删到上一次删除的起点
              (= (edit-desc-e-col d) (edit-desc-s-col pl)))
         (and (= (edit-desc-s-line d) (edit-desc-s-line pl))     ; 前向删除：同点继续删
              (= (edit-desc-s-col d) (edit-desc-s-col pl))))]
    [else #f]))

;;; ---------- 记录 / 取出 ----------

;; 记一步。参数就是 `document-edit` 交回的 `edit-change`（由它拆出 desc / inv / point）。
;; 收 struct 而非三个散值：desc 与 inv 同为 edit-desc，散着传写反了不报错、只静默写坏
;; 历史——打包让这个错变成编译错。
;; 与栈顶可并（同一段连续打字 / 连续删除）则并进去，保留**较早**的 point（撤销回到
;; 整段之前）。任何记录都清空 redo 栈——分叉已被丢弃。
(define (history-record h ch)
  (define desc (edit-change-desc ch))
  (define inv  (edit-change-inv ch))
  (define point (edit-change-pre-point ch))
  (define top (if (pair? (history-undo h)) (car (history-undo h)) #f))
  (cond
    [(and top (step-merge? top desc))
     (struct-copy history h
       [undo (cons (step (append (step-replay-descs top) (list desc))
                         (cons inv (step-undo-descs top))
                         (step-pre-point top))
                   (cdr (history-undo h)))]
       [redo '()])]
    [else
     (struct-copy history h
       [undo (cons (step (list desc) (list inv) point) (history-undo h))]
       [redo '()])]))

;; 取下一步要撤销的 step（移到 redo 栈顶）；空栈 → (values #f h)（原样，不报错）。
(define (history-pop-undo h)
  (cond
    [(null? (history-undo h)) (values #f h)]
    [else
     (define st (car (history-undo h)))
     (values st (struct-copy history h
                  [undo (cdr (history-undo h))]
                  [redo (cons st (history-redo h))]))]))

;; 取下一步要重放的 step（移回 undo 栈顶）；空栈 → (values #f h)。
(define (history-pop-redo h)
  (cond
    [(null? (history-redo h)) (values #f h)]
    [else
     (define st (car (history-redo h)))
     (values st (struct-copy history h
                  [redo (cdr (history-redo h))]
                  [undo (cons st (history-undo h))]))]))

;;; ---------- 测试（纯数据，不碰 document）----------

(module+ test
  (define (ap b d) (let-values ([(b* _) (buffer-apply-edit-trusted b d)]) b*))
  (define (ap-all b ds) (for/fold ([x b]) ([d (in-list ds)]) (ap x d)))

  ;; 模拟组装层的记录路径（编辑前的 buffer 与光标都在手边；edit-fn : buffer → (values buffer desc)）
  (define (rec h b edit-fn p)
    (define-values (b* desc) (edit-fn b))
    (if (not desc)
        (values h b)
        (values (history-record h (edit-change desc (buffer-edit-desc-inverse b desc) p)) b*)))

  ;; 1. 打字连续段：3 次插入并成 1 步
  (define-values (t1 b1) (rec (make-history) (buffer-open "")
                              (lambda (b) (buffer-insert-string b 0 0 "a")) (point 0 0)))
  (define-values (t2 b2) (rec t1 b1 (lambda (b) (buffer-insert-string b 0 1 "b")) (point 0 1)))
  (define-values (t3 b3) (rec t2 b2 (lambda (b) (buffer-insert-string b 0 2 "c")) (point 0 2)))
  (check-equal? (buffer->string b3) "abc")
  (check-equal? (history-undo-depth t3) 1)
  (check-equal? (history-redo-depth t3) 0)
  ;; 撤销：正序应用 undo-descs（它们本就存成撤销次序）→ 回到 ""；point 取**较早**的
  (define-values (s1 t4) (history-pop-undo t3))
  (check-equal? (buffer->string (ap-all b3 (step-undo-descs s1))) "")
  (check-equal? (step-pre-point s1) (point 0 0))
  (check-equal? (history-undo-depth t4) 0)
  (check-equal? (history-redo-depth t4) 1)
  ;; 重放：正序应用 replay-descs → 回到 "abc"
  (define-values (s2 t5) (history-pop-redo t4))
  (check-equal? (buffer->string (ap-all (buffer-open "") (step-replay-descs s2))) "abc")
  (check-equal? (history-undo-depth t5) 1)
  (check-equal? (history-redo-depth t5) 0)

  ;; 1b. insert-char 与 insert-string 都是「单字符插入」，可以互相接续
  (define-values (m1 mb1) (rec (make-history) (buffer-open "")
                               (lambda (b) (buffer-insert-char b 0 0 #\a)) (point 0 0)))
  (define-values (m2 mb2) (rec m1 mb1 (lambda (b) (buffer-insert-string b 0 1 "b")) (point 0 1)))
  (check-equal? (buffer->string mb2) "ab")
  (check-equal? (history-undo-depth m2) 1)

  ;; 2. 换行打断连续段（"\n" 不是「非换行单字符插入」）
  (define-values (n1 nb1) (rec (make-history) (buffer-open "")
                               (lambda (b) (buffer-insert-string b 0 0 "a")) (point 0 0)))
  (define-values (n2 nb2) (rec n1 nb1 (lambda (b) (buffer-newline b 0 1)) (point 0 1)))
  (define-values (n3 nb3) (rec n2 nb2 (lambda (b) (buffer-insert-string b 1 0 "b")) (point 1 0)))
  (check-equal? (buffer->string nb3) "a\nb")
  (check-equal? (history-undo-depth n3) 3)
  ;; 逆序撤销回 ""
  (define-values (ns1 nu1) (history-pop-undo n3))
  (define-values (ns2 nu2) (history-pop-undo nu1))
  (define-values (ns3 _nu3) (history-pop-undo nu2))
  (check-equal? (buffer->string (ap-all (ap-all (ap-all nb3 (step-undo-descs ns1)) (step-undo-descs ns2))
                                        (step-undo-descs ns3)))
                "")

  ;; 3. 退格连续段：向左推进，并成 1 步
  (define-values (k1 kb1) (rec (make-history) (buffer-open "abc")
                               (lambda (b) (buffer-backspace b 0 3)) (point 0 3)))
  (define-values (k2 kb2) (rec k1 kb1 (lambda (b) (buffer-backspace b 0 2)) (point 0 2)))
  (check-equal? (buffer->string kb2) "a")
  (check-equal? (history-undo-depth k2) 1)
  (define-values (ks1 _ku1) (history-pop-undo k2))
  (check-equal? (buffer->string (ap-all kb2 (step-undo-descs ks1))) "abc")
  (check-equal? (step-pre-point ks1) (point 0 3))

  ;; 4. 前向删除连续段：同点继续删，并成 1 步
  (define-values (f1 fb1) (rec (make-history) (buffer-open "abcde")
                               (lambda (b) (buffer-delete b 0 2)) (point 0 2)))
  (define-values (f2 fb2) (rec f1 fb1 (lambda (b) (buffer-delete b 0 2)) (point 0 2)))
  (check-equal? (buffer->string fb2) "abe")
  (check-equal? (history-undo-depth f2) 1)
  (define-values (fs1 _fu1) (history-pop-undo f2))
  (check-equal? (buffer->string (ap-all fb2 (step-undo-descs fs1))) "abcde")

  ;; 5. 粘贴（多字符插入）自成一步，也不并进前面的打字段
  (define-values (p1 pb1) (rec (make-history) (buffer-open "")
                               (lambda (b) (buffer-insert-string b 0 0 "a")) (point 0 0)))
  (define-values (p2 pb2) (rec p1 pb1 (lambda (b) (buffer-insert-string b 0 1 "XY")) (point 0 1)))
  (check-equal? (buffer->string pb2) "aXY")
  (check-equal? (history-undo-depth p2) 2)
  (define-values (ps1 _pu1) (history-pop-undo p2))
  (check-equal? (buffer->string (ap-all pb2 (step-undo-descs ps1))) "a")

  ;; 6. 跨行退格（行合并）不并进删除段
  (define-values (j1 jb1) (rec (make-history) (buffer-open "ab\ncd")
                               (lambda (b) (buffer-backspace b 1 0)) (point 1 0)))
  (check-equal? (buffer->string jb1) "abcd")
  (define-values (j2 jb2) (rec j1 jb1 (lambda (b) (buffer-backspace b 0 2)) (point 0 2)))
  (check-equal? (buffer->string jb2) "acd")
  (check-equal? (history-undo-depth j2) 2)

  ;; 7. 非紧邻的插入不合并
  (define-values (g1 gb1) (rec (make-history) (buffer-open "hello")
                               (lambda (b) (buffer-insert-string b 0 0 "a")) (point 0 0)))
  (define-values (g2 _gb2) (rec g1 gb1 (lambda (b) (buffer-insert-string b 0 3 "b")) (point 0 3)))
  (check-equal? (history-undo-depth g2) 2)

  ;; 8. 替换（非纯插入）自成一步，且不被后续单字符插入并入
  (define-values (r1 rb1) (rec (make-history) (buffer-open "hello")
                               (lambda (b) (buffer-splice b 0 0 0 1 "Z")) (point 0 0)))
  (check-equal? (buffer->string rb1) "Zello")
  (define-values (r2 _rb2) (rec r1 rb1 (lambda (b) (buffer-insert-string b 0 1 "y")) (point 0 1)))
  (check-equal? (history-undo-depth r2) 2)

  ;; 9. 记录新编辑 → redo 栈清空
  (define-values (_c1 c2) (history-pop-undo t3))          ; t3: 打字段一步 → redo 有 1
  (check-equal? (history-redo-depth c2) 1)
  (define-values (c3 _cb) (rec c2 (buffer-open "")
                             (lambda (b) (buffer-insert-string b 0 0 "z")) (point 0 0)))
  (check-equal? (history-redo-depth c3) 0)

  ;; 10. 空栈：pop 返回 #f 且 history 原样（不报错）
  (define empty-h (make-history))
  (define-values (e1 eh1) (history-pop-undo empty-h))
  (check-false e1)
  (check-eq? eh1 empty-h)
  (define-values (e2 eh2) (history-pop-redo empty-h))
  (check-false e2)
  (check-eq? eh2 empty-h)
  (check-false (history-can-undo? empty-h))
  (check-false (history-can-redo? empty-h))
  (check-true (history-can-undo? t3))
  (check-false (history-can-redo? t3))

  (displayln "history.rkt: all tests passed"))
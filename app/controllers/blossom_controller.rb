# BUD-01 Blossom server — serves and accepts content-addressable files by SHA-256 hash.
# Mount at /blossom in routes.
class BlossomController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [ :upload ]

  BLOSSOM_DIR = Rails.root.join("storage", "blossom")

  # GET /blossom/:sha256 — serve a file by hash
  def show
    sha256 = params[:sha256].to_s.downcase
    return head(:bad_request) unless sha256.match?(/\A[0-9a-f]{64}\z/)

    path = blob_path(sha256)
    if File.exist?(path)
      content_type = Marcel::MimeType.for(Pathname.new(path)) rescue "application/octet-stream"
      send_file path, type: content_type, disposition: :inline
    else
      head :not_found
    end
  end

  # HEAD /blossom/:sha256 — check existence
  def check
    sha256 = params[:sha256].to_s.downcase
    return head(:bad_request) unless sha256.match?(/\A[0-9a-f]{64}\z/)

    if File.exist?(blob_path(sha256))
      head :ok
    else
      head :not_found
    end
  end

  # PUT /blossom/upload — accept a file upload
  def upload
    data = request.body.read
    return head(:bad_request) if data.blank?

    sha256 = Digest::SHA256.hexdigest(data)

    # Verify claimed hash if provided
    if params[:sha256].present? || request.headers["X-SHA-256"].present?
      claimed = (params[:sha256] || request.headers["X-SHA-256"]).to_s.downcase
      unless claimed == sha256
        return render json: { error: "SHA-256 mismatch" }, status: :bad_request
      end
    end

    # Store the file
    FileUtils.mkdir_p(BLOSSOM_DIR)
    path = blob_path(sha256)
    File.binwrite(path, data) unless File.exist?(path)

    render json: {
      sha256: sha256,
      url: blossom_url(sha256),
      size: data.bytesize,
      type: request.content_type
    }, status: :ok
  end

  # GET /blossom/list — list stored files (for admin/debugging)
  def list
    return head(:forbidden) unless user_signed_in?

    files = Dir.glob(BLOSSOM_DIR.join("*")).map do |path|
      name = File.basename(path)
      { sha256: name, size: File.size(path), url: blossom_url(name) }
    end

    render json: { files: files, count: files.size }
  end

  private

  def blob_path(sha256)
    BLOSSOM_DIR.join(sha256)
  end

  def blossom_url(sha256)
    "#{request.base_url}/blossom/#{sha256}"
  end
end

import XCTest
import Mechanosynthesis
import Numerics

// A set of tests for solving the 3D potential generated by a nucleus.
//
// Use Neumann boundary conditions for these tests. Also, use the point
// charge model. This would be the multipole expansion of the charge
// distribution created by spreading the nucleus across 8 cells.
final class LinearSolverTests: XCTestCase {
  static let gridSize: Int = 3
  static let h: Float = 2.0 / 3
  
  // Set up the Neumann boundaries, normalize to obey Gauss's Law.
  //
  // Returns an array of fluxes that must be present at the boundary.
  static func createBoundaryConditions() -> [SIMD8<Float>] {
    // Create an array that represents the boundary values in each cell.
    //
    // Elements of the flux data structure:
    // - [0] = lower X face
    // - [1] = upper X face
    // - [2] = lower Y face
    // - [3] = upper Y face
    // - [4] = lower Z face
    // - [5] = upper Z face
    var fluxGrid = [SIMD8<Float>](
      repeating: .zero, count: gridSize * gridSize * gridSize)
    
    // Iterate over all the boundary cells in the grid. Eventually, we will
    // skip some internal cells to save time.
    for indexZ in 0..<gridSize {
      for indexY in 0..<gridSize {
        // Skip some loop iterations to minimize execution time.
        var indicesX: [Int] = []
        if indexY == 0 || indexY == gridSize - 1 ||
            indexZ == 0 || indexZ == gridSize - 1 {
          for indexX in 0..<gridSize {
            indicesX.append(indexX)
          }
        } else {
          indicesX = [0, gridSize - 1]
        }
        
        for indexX in indicesX {
          // Compute the center of the cell.
          let cellCenterX = (Float(indexX) + 0.5) * h
          let cellCenterY = (Float(indexY) + 0.5) * h
          let cellCenterZ = (Float(indexZ) + 0.5) * h
          let cellCenter = SIMD3<Float>(cellCenterX, cellCenterY, cellCenterZ)
          
          // Determine the flux on each face.
          var faceFluxes: SIMD8<Float> = .zero
          for faceID in 0..<6 {
            let coordinateID = faceID / 2
            let signID = faceID % 2
            
            // Compute the center of the face.
            var faceCenter = cellCenter
            let coordinateDelta = (signID == 0) ? Float(-0.5) : 0.5
            faceCenter[coordinateID] += coordinateDelta * h
            
            // Place the nucleus at the midpoint of the 2D grid.
            let nucleusPosition = 0.5 * SIMD3(repeating: Float(gridSize) * h)
            
            // Find the distance and direction from the nucleus.
            let rDelta = faceCenter - nucleusPosition
            let distance = (rDelta * rDelta).sum().squareRoot()
            
            // The potential is always positive, while the gradient is always
            // negative.
            let gradient = -1 / (distance * distance)
            
            // Create the flux vector.
            let direction = rDelta / distance
            let flux = gradient * direction
            
            // Select one scalar of the flux vector.
            var faceFlux = flux[coordinateID]
            faceFlux *= (signID == 0) ? -1 : 1
            faceFluxes[faceID] = faceFlux
          }
          
          // Erase the fluxes on interior faces.
          let indices = SIMD3<Int>(indexX, indexY, indexZ)
          for coordinateID in 0..<3 {
            let index = indices[coordinateID]
            if index != 0 {
              faceFluxes[coordinateID * 2 + 0] = .zero
            }
            if index != gridSize - 1 {
              faceFluxes[coordinateID * 2 + 1] = .zero
            }
          }
          
          // Store the flux data structure to memory.
          var cellID = indexZ * (gridSize * gridSize)
          cellID += indexY * gridSize + indexX
          fluxGrid[cellID] = faceFluxes
        }
      }
    }
    
    // Correct to obey Gauss's Law.
    do {
      // Integrate the fluxes along the domain boundaries.
      var accumulator: Double = .zero
      for cellID in fluxGrid.indices {
        let faceFluxes = fluxGrid[cellID]
        let fluxTerm = faceFluxes.sum()
        let drTerm = h * h
        accumulator += Double(fluxTerm * drTerm)
      }
      let surfaceIntegral = Float(accumulator)
      
      // Rescale to reflect the charge enclosed.
      let chargeEnclosed: Float = 1
      let actual = surfaceIntegral
      let expected = -4 * Float.pi * chargeEnclosed
      let scaleFactor = expected / actual
      
      for cellID in fluxGrid.indices {
        var faceFluxes = fluxGrid[cellID]
        faceFluxes *= scaleFactor
        fluxGrid[cellID] = faceFluxes
      }
    }
    
    // Return the array of flux data structures.
    return fluxGrid
  }
  
  // First, check the solution from the direct matrix method. Make the domain
  // small enough that the direct method executes in ~1 ms. It may be too small
  // to observe a significant speedup from multigrid relaxations, but that is
  // okay. We only need code for a multigrid that works at all.
  func testDirectMatrixMethod() throws {
    // The problem size is the number of cells, plus 6 variables for boundary
    // conditions imposed on each cell. To align the matrix rows to the CPU
    // vector width, we pad the number 6 to 8.
    let n = (Self.gridSize * Self.gridSize * Self.gridSize) + 8
    
    // Allocate a matrix and two vectors.
    var laplacian = [Float](repeating: .zero, count: n * n)
    var potential = [Float](repeating: .zero, count: n)
    var chargeDensity = [Float](repeating: .zero, count: n)
    
    // Set the eight extraneous variables to the identity. These variables
    // adapt the boundary conditions to the functional form of a
    // matrix operator.
    do {
      let constraintStart = Self.gridSize * Self.gridSize * Self.gridSize
      let constraintEnd = constraintStart + 8
      for constraintID in constraintStart..<constraintEnd {
        // Fill in a diagonal of the matrix.
        let diagonalAddress = constraintID * n + constraintID
        laplacian[diagonalAddress] = 1
        
        // Fill in the tail of each vector.
        potential[constraintID] = 1
        chargeDensity[constraintID] = 1
      }
    }
    
    // Fetch the boundary conditions.
    let boundaryConditions = Self.createBoundaryConditions()
    
    // Fill in the entries of the matrix.
    for indexZ in 0..<Self.gridSize {
      for indexY in 0..<Self.gridSize {
        for indexX in 0..<Self.gridSize {
          let indices = SIMD3<Int>(indexX, indexY, indexZ)
          var cellID = indexZ * (Self.gridSize * Self.gridSize)
          cellID += indexY * Self.gridSize + indexX
          
          // Fetch any possible boundary conditions.
          let faceFluxes = boundaryConditions[cellID]
          
          // Iterate over the faces.
          var linkedCellCount: Int = .zero
          for faceID in 0..<6 {
            let coordinateID = faceID / 2
            let signID = faceID % 2
            var coordinate = indices[coordinateID]
            coordinate += (signID == 0) ? -1 : 1
            
            // Link this variable to another one.
            if coordinate >= 0, coordinate < Self.gridSize {
              linkedCellCount += 1
              
              // Establish the relationship between this cell and the linked
              // cell, with a matrix entry.
              var otherIndices = indices
              otherIndices[coordinateID] = coordinate
              var otherCellID = otherIndices.z * (Self.gridSize * Self.gridSize)
              otherCellID += otherIndices.y * Self.gridSize + otherIndices.x
              
              // Assign 1 / h^2 to the linking entry.
              let linkAddress = cellID * n + otherCellID
              let linkEntry: Float = 1 / (Self.h * Self.h)
              laplacian[linkAddress] = linkEntry
            } else {
              // Impose a boundary condition, as there are no cells to fetch
              // data from.
              let faceFlux = faceFluxes[faceID]
              
              // Assign F / h to the linking entry.
              let cellCount = Self.gridSize * Self.gridSize * Self.gridSize
              let linkAddress = (cellID * n + cellCount) + faceID
              let linkEntry: Float = faceFlux / Self.h
              laplacian[linkAddress] = linkEntry
            }
          }
          
          // Write the entry along the diagonal (most often -6 / h^2).
          let diagonalEntry = -Float(linkedCellCount) / (Self.h * Self.h)
          let diagonalAddress = cellID * n + cellID
          laplacian[diagonalAddress] = diagonalEntry
        }
      }
    }
    
    #if false
    // Visualize the matrix.
    for rowID in 0..<n {
      for columnID in 0..<n {
        // Fetch the entry.
        let address = rowID * n + columnID
        let entry = laplacian[address]
        
        // Create a string representation.
        //  X.YZ
        // -X.YZ
        //  XY.Z
        // -XY.Z
        var repr = String(format: "%.2f", entry)
        if entry.sign == .plus {
          repr = " " + repr
        }
        if repr.count > 5 {
          repr.removeLast()
        }
        
        // Choose a color.
        func makeGreen<T: StringProtocol>(_ string: T) -> String {
          "\u{1b}[0;32m\(string)\u{1b}[0m"
        }
        func makeYellow<T: StringProtocol>(_ string: T) -> String {
          "\u{1b}[0;33m\(string)\u{1b}[0m"
        }
        func makeCyan<T: StringProtocol>(_ string: T) -> String {
          "\u{1b}[0;36m\(string)\u{1b}[0m"
        }
        if entry != Float.zero {
          let cellCount = Self.gridSize * Self.gridSize * Self.gridSize
          if rowID >= cellCount || columnID >= cellCount {
            // Highlight boundary conditions in yellow.
            repr = makeYellow(repr)
          } else {
            // Highlight data links in green.
            repr = makeGreen(repr)
          }
        }
        
        // Render the entry.
        print(repr, terminator: " ")
      }
      print()
    }
    #endif
  }
  
  // Implementation of the algorithm from the INQ codebase, which chooses the
  // timestep based on the results of some integrals.
  func testSteepestDescent() throws {
    
  }
  
  // Implementation of weighted Jacobi, using a fixed timestep determined by
  // the grid spacing.
  func testWeightedJacobi() throws {
    
  }
  
  // Implementation of Gauss-Seidel, using a fixed timestep determined by the
  // grid spacing.
  //
  // This test does not cover the Gauss-Seidel red-black ordering scheme.
  // However, the results should reveal how one would go about coding GSRB.
  func testGaussSeidel() throws {
    
  }
  
  // Implementation of the algorithm from the INQ codebase, which chooses the
  // timestep based on the results of some integrals.
  func testConjugateGradient() throws {
    
  }
  
  // Multigrid solver. There's currently a big unknown regarding how the grid
  // should treat domain boundaries.
  func testMultigrid() throws {
    
  }
}
